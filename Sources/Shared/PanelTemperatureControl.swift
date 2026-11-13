import SwiftUI

// Identical control layout and setpoint stepping on Mac and iPhone.
struct PanelTemperatureControl: View {
    var name: String
    var targetValue: String
    var powerOn: Bool?
    var temperatureOptions: [Int]
    var changeTemperature: ((Int) -> Void)?
    var turnOff: (() -> Void)? = nil
    var ecoEnabled = false
    var directions: AnyView? = nil
    var trailingControl: AnyView? = nil
    #if os(iOS)
    private let stepSize: CGFloat = 44
    private let stepHeight: CGFloat = 44
    #else
    private let stepSize: CGFloat = 30
    private let stepHeight: CGFloat = 34
    #endif
    private var targetDegrees: Double? {
        Double(targetValue.prefix { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }.replacingOccurrences(of: ",", with: "."))
    }
    private func adjacentTemperature(_ delta: Int) -> Int? {
        guard let targetDegrees else { return nil }
        return delta < 0 ? temperatureOptions.filter { Double($0) < targetDegrees }.max() : temperatureOptions.filter { Double($0) > targetDegrees }.min()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Set temperature").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let changeTemperature {
                    temperatureStep(-1, change: changeTemperature)
                    HStack(spacing: 2) {
                        TemperaturePicker(value: targetValue, degrees: temperatureOptions, off: turnOff, choose: changeTemperature, fontSize: 38)
                        if ecoEnabled { Image(systemName: "leaf.fill").font(.system(size: 12)).foregroundStyle(leafGreen) }
                    }
                    temperatureStep(1, change: changeTemperature)
                } else { Text(targetValue).font(.system(size: 28, weight: .semibold)) }
                if let trailingControl { trailingControl }
                Spacer(minLength: 2)
                if let directions { Rectangle().fill(.white.opacity(0.25)).frame(width: 0.5, height: 32); directions.frame(width: 116) }
                if let turnOff {
                    Button(action: turnOff) { Image(systemName: "power").font(.system(size: 22)).frame(width: 38, height: 36).contentShape(Rectangle()) }
                        .buttonStyle(.plain).deviceSurface(selected: false).foregroundStyle(powerOn == false ? Color.red : .white)
                        .help("Turn off").accessibilityLabel("Turn off " + DeviceDisplayName.clean(name)).disabled(powerOn != true)
                }
            }
        }
    }
    private func temperatureStep(_ delta: Int, change: @escaping (Int) -> Void) -> some View {
        let next = adjacentTemperature(delta)
        return Button { if let next { change(next) } } label: {
            Image(systemName: delta < 0 ? "minus" : "plus").font(.system(size: 18, weight: .medium))
                .frame(width: stepSize, height: stepHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).background(.white.opacity(0.04), in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5)).disabled(next == nil || powerOn == nil)
            .accessibilityLabel(delta < 0 ? "Decrease set temperature" : "Increase set temperature")
    }
}

struct TemperaturePicker: View {
    let value:String
    let degrees:[Int]
    let off:(() -> Void)?
    let choose:(Int)->Void
    var fontSize: CGFloat = 15
    @State private var presented = false
    private var popoverEdge: Edge {
        #if os(iOS)
        return .top
        #else
        return .bottom
        #endif
    }
    var body: some View {
        Button { presented.toggle() } label: { Text(value).font(.system(size:fontSize,weight:.semibold)).fixedSize() }
            .buttonStyle(.plain).help("Set temperature")
            .accessibilityLabel("Choose temperature, " + value)
            .disabled(degrees.isEmpty)
            .popover(isPresented:$presented,arrowEdge:popoverEdge) {
                let split = (degrees.count+1)/2
                VStack(spacing:6) {
                    ForEach(0..<split,id:\.self) { row in
                        HStack(spacing:8) {
                            ForEach(0..<2) { column in
                                let index = row + column * split
                                if degrees.indices.contains(index) {
                                    let degree = degrees[index]
                                    let selected = value.replacingOccurrences(of:"°",with:"").trimmingCharacters(in:.whitespaces) == String(degree)
                                    Button { choose(degree); presented = false } label: {
                                        Label { Text(String(degree)+" °C") } icon: { Image(systemName:"thermometer.medium") }
                                            .font(.system(size:14)).frame(width:92,height:32)
                                            .background(selected ? cobalt.opacity(0.6) : SuperBarPanelStyle.panel,in:RoundedRectangle(cornerRadius:4))
                                            .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(selected ? Color.white : .clear,lineWidth:1))
                                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                                } else { Color.clear.frame(width:92,height:32) }
                            }
                        }
                    }
                    if let off { Button { off(); presented = false } label: { Label("OFF",systemImage:"power").foregroundStyle(.red).frame(maxWidth:.infinity,minHeight:28) }.buttonStyle(.plain) }
                }.padding(10).background(PanelPalette.background.color)
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
    }
}
