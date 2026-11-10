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
