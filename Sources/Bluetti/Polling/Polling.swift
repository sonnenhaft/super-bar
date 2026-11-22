import AppKit

enum PollInterval: Int, CaseIterable {
    case oneSecond = 1, threeSeconds = 3, fiveSeconds = 5
    case fifteenSeconds = 15, twentySeconds = 20, thirtySeconds = 30, oneMinute = 60, twoMinutes = 120

    var label: String { rawValue < 60 ? "\(rawValue)s" : "\(rawValue / 60)m" }
    var keepsConnection: Bool { rawValue <= 5 }
}

extension BlueBarDelegate {
    var pollDelay: TimeInterval {
        if consecutiveReadFailures == 1 { return min(3, refreshInterval) }
        return consecutiveReadFailures > maximumReadRetries ? max(120, refreshInterval) : refreshInterval
    }

    func restartPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard bluetoothActivated, !quitting, !streaming else { return }
        let timer = Timer(timeInterval: pollDelay, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func restartAgeTimer() {
        ageTimer?.invalidate()
        ageTimer = nil
        guard !quitting, lastError == nil, let sample = lastGood else { return }
        let delay = max(0.01, sample.measuredAt.addingTimeInterval(maximumAge).timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.checkAge() }
        RunLoop.main.add(timer, forMode: .common)
        ageTimer = timer
    }

    func resetReadRetryBudget() {
        consecutiveReadFailures = 0
        nextReadRetryAt = nil
        restartPollTimer()
        restartAgeTimer()
    }

    func finishManualRead(error: String?) {
        if manualRead == .reading {
            manualRead = nil
            lastManualRefreshError = error
        } else if error == nil {
            lastManualRefreshError = nil
        }
    }

    // Only a failed station-read attempt reaches this method. Restore,
    // staleness, sleep and cancelled/obsolete generations do not spend retries.
    func readFailed(_ error: String, confirmedFailure: Bool = true) {
        finishManualRead(error: error)
        if confirmedFailure, let key = connectedStationKey ?? primaryDiscoveryKey ?? selectedKnownStation?.key {
            stationContacts[key] = .failed
        }
        connectedStationKey = nil
        refreshState = refreshState == .connecting ? .connectFailed : .readFailed
        consecutiveReadFailures += 1
        nextReadRetryAt = Date().addingTimeInterval(pollDelay)
        restartPollTimer()
        fail(error)
    }

    func stopPollingSession() {
        guard streaming else { return }
        connectedStationKey = nil
        generation += 1
        pendingRefresh = true
        manualRead = isManuallyRefreshing ? .queued : nil
        streaming = false
        restartPollTimer()
        job?.cancel()
    }

    @objc func refreshClicked() {
        guard bluetoothActivated, !sleeping, !quitting, !isManuallyRefreshing else { return }
        resetReadRetryBudget()
        lastManualRefreshError = nil
        manualRead = .reading
        guard let job else { refresh(); return }
        // A read already underway will deliver fresh registers for this click.
        if !isLoadingReading {
            if streaming && job.requestImmediateRead() {
                refreshState = .reading
            } else {
                // A one-shot or exiting helper must release its lock before retrying.
                pendingRefresh = true
                manualRead = .queued
            }
        }
        render()
    }

    func refresh() {
        guard bluetoothActivated, !sleeping, !quitting, job == nil else { return }
        if let retryAt = nextReadRetryAt, Date() < retryAt { return }
        if let stationPreview, stationPreview.key == selectedKnownStation?.key {
            pendingRefresh = true
            return
        }
        pendingRefresh = false
        if manualRead == .queued { manualRead = .reading }
        if demo {
            let snapshot: [String: Any] = [
                "ok": true, "model": "AC50P", "device": "DEMO — no station connected",
                "battery_percent": 73, "observed_at": Date().timeIntervalSince1970,
                "ac_input_w": 0, "dc_input_w": 0, "ac_output_w": 120, "dc_output_w": 15,
                "runtime": ["state": "discharging", "source": "soc_history", "remaining_seconds": 14_600,
                            "window_seconds": 600, "drop_percent": 3] as [String: Any],
                "demo": true
            ]
            accept(snapshot)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            readFailed("Bluetooth reader is missing. Reinstall Super Bar to restore the app executable.")
            return
        }
        let read = CLIJob()
        let thisGeneration = generation
        job = read
        refreshState = .connecting
        streaming = selectedInterval.keepsConnection
        var arguments = ["status", "--timeout", "13"]
        if streaming {
            arguments.insert(contentsOf: ["--poll-session", String(selectedInterval.rawValue)], at: 0)
            pollTimer?.invalidate()
            pollTimer = nil
        }
        arguments.insert("--menu-read", at: 0)
        if !identifier.isEmpty { arguments += ["--device", identifier] }
        render()
        let receive: ([String: Any]) -> Void = { [weak self, weak read] snapshot in
            DispatchQueue.main.async {
                guard let self = self, let read = read, self.job === read,
                      self.generation == thisGeneration, !self.sleeping, !self.quitting else { return }
                if snapshot["phase"] as? String == "discovered",
                   let devices = snapshot["devices"] as? [[String: Any]] {
                    if self.stationDirectory.observeNearby(devices), self.mainMenuIsOpen { self.render() }
                    self.updateStationPreviews(devices)
                    return
                }
                if snapshot["phase"] as? String == "connected",
                   let device = snapshot["device"] as? [String: Any], let name = device["name"] as? String {
                    self.connectedStationKey = self.stationDirectory.station(deviceID: device["id"] as? String, bluetoothName: name)?.key
                    self.render()
                    return
                }
                if snapshot["phase"] as? String == "disconnected" {
                    if self.connectedStationKey != nil {
                        self.connectedStationKey = nil
                        self.render()
                    }
                    return
                }
                if snapshot["phase"] as? String == "reading" {
                    self.refreshState = .reading
                    if self.mainMenuIsOpen { self.render() }
                    return
                }
                if !self.accept(snapshot) {
                    // accept already recorded the failure and scheduled the retry.
                    self.generation += 1
                    read.cancel(reason: "Invalid station reading.")
                } else if self.streaming && self.pendingRefresh && read.requestImmediateRead() {
                    self.pendingRefresh = false
                    if self.manualRead == .queued { self.manualRead = .reading }
                    self.refreshState = .reading
                    self.render()
                }
                self.readStationPreviewIfDue()
            }
        }
        read.run(executable: helperURL, arguments: arguments, sampleInterval: streaming ? refreshInterval : 0,
                 onSample: receive) { [weak self, weak read] result in
            DispatchQueue.main.async {
                guard let self = self, let read = read, self.job === read else { return }
                self.job = nil
                let lostConnection = self.connectedStationKey != nil
                self.connectedStationKey = nil
                if self.streaming {
                    self.streaming = false
                    self.restartPollTimer()
                }
                if self.quitting {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                if thisGeneration != self.generation || self.sleeping {
                    self.render()
                } else if result.error != nil || result.exitCode != 0 || !result.stdout.isEmpty {
                    self.handle(result)
                } else if self.manualRead == .reading {
                    self.readFailed("Station disconnected before returning a reading.")
                } else if lostConnection {
                    self.render()
                }
                self.runQueuedWork()
            }
        }
    }

    private func updateStationPreviews(_ rows: [[String: Any]]) {
        let devices = rows.compactMap { row -> BluettiNativeDevice? in
            guard row["model"] as? String == "AC50P", let id = row["id"] as? String,
                  UUID(uuidString: id) != nil, let name = row["name"] as? String else { return nil }
            return BluettiNativeDevice(id: id, name: name)
        }
        let primary = try? bluettiChooseDevice(devices, selector: identifier.isEmpty ? devices.first?.id : identifier)
        primaryDiscoveryKey = connectedStationKey ?? primary.map { "id:" + $0.id } ?? selectedKnownStation?.key
        for device in devices { previewDevices[device.id] = device }
        readStationPreviewIfDue()
    }

    // Use one bounded read at a time for the other cards. Neither opening
    // the panel nor selecting a card interrupts the selected station's stream.
    private func readStationPreviewIfDue() {
        guard stationPreview == nil, bluetoothActivated, !demo, !sleeping, !quitting else { return }
        let now = Date()
        let selectedKey = identifier.isEmpty ? primaryDiscoveryKey : selectedKnownStation?.key
        guard let device = previewDevices.values.first(where: {
            let key = "id:" + $0.id
            return key != selectedKey && key != primaryDiscoveryKey && (previewAfter[key] ?? .distantPast) <= now
        }) else { return }
        let key = "id:" + device.id
        previewAfter[key] = now.addingTimeInterval(max(60, previewInterval))
        let read = CLIJob()
        stationPreview = (key, read)
        read.run(executable: helperURL, arguments: ["--station-preview", "status", "--device", device.id, "--timeout", "13"]) { [weak self, weak read] result in
            DispatchQueue.main.async {
                guard let self, let read, self.stationPreview?.job === read else { return }
                self.stationPreview = nil
                guard self.bluetoothActivated, !self.sleeping, !self.quitting else { return }
                let payload = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
                if result.exitCode == 0, result.error == nil, let payload,
                   self.saveStationPreview(payload, deviceID: device.id) {
                    self.previewAfter[key] = now.addingTimeInterval(self.previewInterval)
                } else if result.error == nil, let code = payload?["code"] as? String,
                          !["not_found", "busy", "filesystem", "cancelled"].contains(code) {
                    self.stationContacts[key] = .failed
                }
                self.render()
                self.runQueuedWork()
                self.readStationPreviewIfDue()
            }
        }
    }

    @MainActor func saveStationPreview(_ snapshot: [String: Any], deviceID: String) -> Bool {
        guard let reading = try? Reading.decode(snapshot, previous: nil, now: Date(), maximumAge: nil),
              reading.deviceID?.lowercased() == deviceID,
              readingStore.save(snapshot, rememberSelection: false) else { return false }
        outputHistory.record(reading.outputWatts, for: "id:" + deviceID, at: reading.measuredAt)
        stationContacts["id:" + deviceID] = .sample(reading.measuredAt)
        return true
    }

    func handle(_ result: CLIResult) {
        if let error = result.error { readFailed(error); return }
        let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
        if result.exitCode != 0 || object?["ok"] as? Bool != true {
            let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (object?["error"] as? String)
                ?? (stderr?.isEmpty == false ? stderr! : "Reader returned no valid status (exit \(result.exitCode)).")
            let code = object?["code"] as? String
            readFailed(detail, confirmedFailure: code != "not_found" && code != "busy" && code != "filesystem")
            return
        }
        guard let snapshot = object else { readFailed("Reader returned invalid JSON."); return }
        accept(snapshot)
    }

    func fail(_ error: String, offline: Bool = true) {
        awaitingFirstRead = false
        lastError = error
        hasConnectionFailure = offline
        freezeRuntime()
        saveReadingState()
        loadHistory.markGap()
        writeFailure(error)
        render()
    }

    private func checkAge() {
        guard !quitting, let reading = lastGood, lastError == nil else { return }
        if Date().timeIntervalSince(reading.measuredAt) >= maximumAge {
            fail("Reading is stale; waiting for a fresh Bluetooth sample.", offline: connectedStationKey == nil)
        } else { restartAgeTimer() }
    }

    func runQueuedWork() {
        guard pendingRefresh, !sleeping, !quitting, job == nil else { return }
        nextReadRetryAt = nil
        refresh()
    }
}
