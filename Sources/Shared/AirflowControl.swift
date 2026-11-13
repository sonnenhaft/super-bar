import SwiftUI

struct TCLAirflowPicker: View {
    let ac: Aircon
    let vertical: Bool
    let choose: (String, Int) -> Void
    @State private var presented = false
    private var axis: String { vertical ? "vertical" : "horizontal" }
    private var title: String { vertical ? "Vertical" : "Horizontal" }
    private var hasDirection: Bool { ac.has(axis + "Direction") }
    private var options: [Int] {
        hasDirection ? Array(9...13) + Array(1...(vertical ? 3 : 4)) + [8] : [1, 0]
    }
    private var selected: Int? {
        guard hasDirection else { return ac.code(axis + "Switch") }
        let code = ac.code(axis + "Direction")
        return ac.code(axis + "Switch") == 0 && !(9...13).contains(code ?? -1) ? 8 : code
    }
    private func label(_ option: Int) -> String {
        if !hasDirection { return option == 0 ? "Stop" : "Swing" }
        if option == 8 { return "Stop" }
        if (9...13).contains(option) { return (vertical ? verticalStops : horizontalStops)[option - 9] }
        let swings = vertical ? ["Up and down", "Upper zone", "Lower zone"] : ["Left to right", "Left zone", "Center zone", "Right zone"]
        return swings[option - 1]
    }
    #if os(iOS)
    private let buttonHeight: CGFloat = 44
    private let optionSize: CGFloat = 44
    private let popoverEdge: Edge = .top
    #else
    private let buttonHeight: CGFloat = 34
    private let optionSize: CGFloat = 36
    private let popoverEdge: Edge = .bottom
    #endif
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 3) {
                icon(selected).frame(width: 28, height: 28)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.frame(width: 58, height: buttonHeight).deviceSurface(selected: presented)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.white)
            .disabled(!hasDirection && !ac.has(axis + "Switch"))
            .accessibilityLabel(title + " air direction").accessibilityValue(ac.vane(vertical))
            .help(title + ": " + ac.vane(vertical))
            .popover(isPresented: $presented, arrowEdge: popoverEdge) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(optionSize), spacing: 8), count: min(5, options.count)), spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            presented = false
                            choose(axis + (hasDirection ? "Direction" : "Switch"), option)
                        } label: {
                            icon(option).frame(width: 28, height: 28)
                                .frame(width: optionSize, height: optionSize)
                                .deviceSurface(selected: selected == option)
                        }.buttonStyle(.plain)
                            .foregroundStyle(selected == option ? SuperBarPanelStyle.cyan : .white)
                            .accessibilityLabel(label(option)).help(label(option))
                            .accessibilityAddTraits(selected == option ? .isSelected : [])
                    }
                }.padding(12).background(PanelPalette.background.color)
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
    }
    @ViewBuilder private func icon(_ option: Int?) -> some View {
        let code = hasDirection ? option : (option == 1 ? 1 : 8)
        if let code, let url = Bundle.main.url(forResource: "TCL-\(axis)-\(code)", withExtension: "png") {
            #if os(iOS)
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
            }
            #else
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            }
            #endif
        } else {
            Image(systemName: option == nil ? "questionmark.circle" : "stop.circle").resizable().scaledToFit()
        }
    }
}
