// Battery autonomy at the measured output load, assuming all input is removed.
enum AC50PAutonomy {
    static func externalInput(grid: Bool?, acWatts: Int?, dcWatts: Int?) -> Bool? {
        if grid == true || (acWatts ?? 0) > 0 || (dcWatts ?? 0) > 0 { return true }
        return acWatts == 0 && dcWatts == 0 ? false : nil
    }

    static func seconds(percent: Int, acWatts: Int?, dcWatts: Int?) -> Int? {
        guard (0...100).contains(percent), let ac = acWatts, let dc = dcWatts,
              ac >= 0, dc >= 0, ac > 0 || dc > 0 else { return nil }
        // AC50P: 504 Wh, 90% usable capacity, 85% conversion efficiency, 10 W overhead.
        let usableWh = 504.0 * 0.90 * 0.85 * Double(percent) / 100
        return Int((3600 * usableWh / (Double(ac) + Double(dc) + 10)).rounded())
    }

    static func runtimeLabel(percent: Int, reported: Int?, externalInput: Bool?, acWatts: Int?, dcWatts: Int?) -> String {
        let duration: Int
        let backup: Bool
        if externalInput != true, let reported, (1...(998 * 360)).contains(reported) || (reported == 0 && percent == 0) {
            duration = reported
            backup = false
        } else if let estimate = seconds(percent: percent, acWatts: acWatts, dcWatts: dcWatts) {
            duration = estimate
            backup = externalInput != false
        } else {
            return acWatts == 0 && dcWatts == 0 ? "No output load" : "Runtime unavailable"
        }
        let minutes = duration / 60
        let time: String
        if minutes >= 60 { time = "\(minutes / 60)h \(minutes % 60)m" }
        else if duration > 0 && minutes == 0 { time = "<1m" }
        else { time = "\(minutes)m" }
        return backup ? "Backup ≈ " + time : "≈ " + time + " left"
    }
}

// Register 104 is a charge ETA only while power is going into the battery.
// The AC50P can also pass input power directly through to its outputs.
enum AC50PChargeTime {
    static func seconds(reported: Int?, percent: Int, acIn: Int?, dcIn: Int?,
                        acOut: Int?, dcOut: Int?) -> Int? {
        guard let reported, (1...(998 * 360)).contains(reported), (0..<100).contains(percent),
              let acIn, let dcIn, let acOut, let dcOut,
              acIn + dcIn >= acOut + dcOut + 20 else { return nil }
        return reported
    }
}
