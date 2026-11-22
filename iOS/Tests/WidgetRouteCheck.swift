import Foundation

@main enum WidgetRouteCheck {
    static func main() {
        let specialIDs = ["bedroom", "same-id", "офис / A&B?x=#1% +", "AA:BB:CC:DD", "💡 room"]
        var routes: [WidgetRoute] = [.home, .settings, .climate(nil), .battery(nil), .energy(nil)]
        for id in specialIDs { routes += [.climate(.tcl(id)), .climate(.lg(id)), .battery(id)] }
        routes += WidgetRoute.EnergyComponent.allCases.map { .energy($0) }
        for route in routes {
            precondition(WidgetRoute(url: route.url) == route, "Widget and app disagree about the selected component: \(route)")
        }
        precondition(WidgetRoute.climate(.tcl("same-id")).url != WidgetRoute.climate(.lg("same-id")).url,
                     "Provider identity must survive identical device IDs and names")
        for section in ["home", "settings", "climate", "battery", "energy"] {
            precondition(WidgetRoute(url: URL(string: "superbar://" + section)!)?.section == section,
                         "Previously installed widgets must still open their section")
        }
        let invalid = ["https://climate?brand=LG&id=x", "superbar://other", "superbar://climate?id=x",
                       "superbar://climate?brand=OTHER&id=x", "superbar://climate?brand=LG&id=",
                       "superbar://climate?brand=LG&id=a&id=b", "superbar://climate?brand=LG&id=x&temperature=16",
                       "superbar://battery?id=a&connect=true", "superbar://battery?id=%0A",
                       "superbar://energy?component=unknown", "superbar://energy?component=load&component=solar",
                       "superbar://home?command=power", "superbar://user:pass@battery?id=x",
                       "superbar://battery:123?id=x", "superbar://battery/other?id=x", "superbar://battery?id=x#other"]
        for value in invalid {
            precondition(WidgetRoute(url: URL(string: value)!) == nil, "Unexpected navigation or command accepted: \(value)")
        }
        precondition(WidgetRoute(url: WidgetRoute.battery(String(repeating: "x", count: 513)).url) == nil)
        print("Widget links: exact provider/device, both stations, all four energy components, Unicode IDs, old links and invalid/control URLs verified. No device commands sent.")
    }
}
