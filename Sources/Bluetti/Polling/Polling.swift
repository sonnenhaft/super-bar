import AppKit

enum PollInterval: Int, CaseIterable {
    case oneSecond = 1, threeSeconds = 3, fiveSeconds = 5
    case twentySeconds = 20, thirtySeconds = 30, oneMinute = 60, twoMinutes = 120

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

    // Only a failed station-read attempt reaches this method. Restore,
    // staleness, sleep and cancelled/obsolete generations do not spend retries.
    func readFailed(_ error: String) {
        refreshState = refreshState == .connecting ? .connectFailed : .readFailed
        consecutiveReadFailures += 1
        nextReadRetryAt = Date().addingTimeInterval(pollDelay)
        restartPollTimer()
        fail(error)
    }

    func stopPollingSession() {
        guard streaming else { return }
        generation += 1
        pendingRefresh = true
        job?.cancel()
    }

    @objc func refreshClicked() {
        guard !sleeping, !quitting else { return }
        bluetoothActivated = true
        resetReadRetryBudget()
        if job == nil {
            refresh()
        } else if streaming && !isLoadingReading {
            job?.requestImmediateRead()
            refreshState = .reading
            render()
        } else {
            pendingRefresh = true
        }
    }

    func refresh() {
        guard bluetoothActivated, !sleeping, !quitting, job == nil else { return }
        if let retryAt = nextReadRetryAt, Date() < retryAt { return }
        pendingRefresh = false
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
            readFailed("Bluetooth reader is missing. Reinstall BluettiBar to restore the app executable.")
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
                } else if self.streaming && self.pendingRefresh {
                    self.pendingRefresh = false
                    read.requestImmediateRead()
                    self.refreshState = .reading
                    self.render()
                }
            }
        }
        read.run(executable: helperURL, arguments: arguments,
                 onSample: receive) { [weak self, weak read] result in
            DispatchQueue.main.async {
                guard let self = self, let read = read, self.job === read else { return }
                self.job = nil
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
                }
                self.runQueuedWork()
            }
        }
    }

    func handle(_ result: CLIResult) {
        if let error = result.error { readFailed(error); return }
        let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
        if result.exitCode != 0 || object?["ok"] as? Bool != true {
            let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (object?["error"] as? String)
                ?? (stderr?.isEmpty == false ? stderr! : "Reader returned no valid status (exit \(result.exitCode)).")
            readFailed(detail)
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
            fail("Reading is stale; waiting for a fresh Bluetooth sample.")
        } else { restartAgeTimer() }
    }

    func runQueuedWork() {
        guard pendingRefresh, !sleeping, !quitting, job == nil else { return }
        nextReadRetryAt = nil
        refresh()
    }
}
