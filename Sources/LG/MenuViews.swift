import AppKit

private let lgEmblem: NSImage = {
  let im = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
    NSColor(calibratedRed: 0.65, green: 0, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 18, height: 18)).fill()
    NSColor.white.setStroke()
    let p = NSBezierPath()
    p.lineWidth = 0.9
    p.appendArc(
      withCenter: NSPoint(x: 9, y: 9), radius: 6.4, startAngle: 40, endAngle: 0, clockwise: false)
    p.move(to: NSPoint(x: 15.4, y: 9))
    p.line(to: NSPoint(x: 10.4, y: 9))
    p.stroke()
    let l = NSBezierPath()
    l.lineWidth = 0.9
    l.move(to: NSPoint(x: 8.4, y: 13))
    l.line(to: NSPoint(x: 8.4, y: 5.3))
    l.line(to: NSPoint(x: 11, y: 5.3))
    l.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 4.8, y: 11.3, width: 1.5, height: 1.5)).fill()
    return true
  }
  return im
}()
func lgIcon() -> NSImage { lgEmblem }
@MainActor class MenuHoverView: NSView {
  private var mouseArea: NSTrackingArea?
  private var hovered = false
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    guard mouseArea == nil else { return }
    let area = NSTrackingArea(
      rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self,
      userInfo: nil)
    addTrackingArea(area)
    mouseArea = area
  }
  override func mouseEntered(with event: NSEvent) {
    hovered = true
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7)
    NSColor.controlBackgroundColor.setFill(); card.fill()
    if hovered {
      BarTheme.cobalt.withAlphaComponent(0.12).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
  }
}
@MainActor final class ActionRow: MenuHoverView {
  let button = NSButton()
  let right = NSTextField(labelWithString: "")
  var action: (() -> Void)?
  init(
    _ title: String, _ suffix: String = "", _ color: NSColor = .labelColor,
    _ action: @escaping () -> Void
  ) {
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 25))
    self.action = action
    button.frame = NSRect(x: 13, y: 1, width: 230, height: 23)
    button.title = title
    button.isBordered = false
    button.alignment = .left
    button.font = .menuFont(ofSize: 13)
    button.target = self
    button.action = #selector(click)
    addSubview(button)
    right.frame = NSRect(x: 223, y: 4, width: 62, height: 18)
    right.alignment = .right
    right.stringValue = suffix
    right.textColor = color
    right.font = .menuFont(ofSize: 13)
    addSubview(right)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : button }
  @objc func click() { action?() }
}
@MainActor final class MenuSlider: NSSlider {
  var committed: (() -> Void)?
  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    committed?()
  }
}
@MainActor final class SliderRow: MenuHoverView {
  let slider: MenuSlider
  var commitOnRelease = false
  let label = NSTextField(labelWithString: "")
  var changed: ((Double) -> Void)?
  var format: (Double) -> String
  init(
    value: Double, min: Double, max: Double, ticks: Int = 0, format: @escaping (Double) -> String,
    changed: @escaping (Double) -> Void
  ) {
    self.format = format
    self.changed = changed
    slider = MenuSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
    slider.frame = NSRect(x: 14, y: 4, width: 208, height: 24)
    slider.trackFillColor = BarTheme.cobalt
    slider.target = self
    slider.action = #selector(move)
    slider.isContinuous = true
    slider.numberOfTickMarks = ticks
    slider.allowsTickMarkValuesOnly = ticks > 0
    addSubview(slider)
    label.frame = NSRect(x: 228, y: 7, width: 60, height: 20)
    slider.committed = { [weak self] in
      guard let self = self, self.commitOnRelease else { return }
      self.changed?(self.slider.doubleValue)
    }
    label.stringValue = format(value)
    label.alignment = .right
    label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  func topLabel(_ title: String) {
    setFrameSize(NSSize(width: frame.width, height: 46))
    let caption = NSTextField(labelWithString: title)
    caption.font = .menuFont(ofSize: 12)
    caption.frame = NSRect(x: 13, y: 27, width: 208, height: 16)
    addSubview(caption)
    slider.setAccessibilityLabel(title)
  }
  @objc func move() {
    label.stringValue = format(slider.doubleValue)
    if !commitOnRelease || NSApp.currentEvent?.type == .keyDown { changed?(slider.doubleValue) }
  }
}

func temperatureStack(room: String, outside: String, fontSize: CGFloat, color: NSColor) -> NSAttributedString {
  let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize * 0.7, weight: .medium)
  let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
  let top = TemperatureStyle.attributed(NSAttributedString(string: room, attributes: attributes), menuBar: true)
  let bottom = TemperatureStyle.attributed(NSAttributedString(string: outside, attributes: attributes), menuBar: true)
  let lineHeight = ceil(max(top.size().height, bottom.size().height))
  let size = NSSize(width: ceil(max(top.size().width, bottom.size().width)), height: lineHeight * 2)
  let image = NSImage(size: size, flipped: false) { _ in
    top.draw(at: NSPoint(x: 0, y: lineHeight))
    bottom.draw(at: .zero)
    return true
  }
  let attachment = NSTextAttachment()
  attachment.image = image
  let fullFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
  attachment.bounds = NSRect(
    x: 0, y: (fullFont.capHeight - size.height) / 2, width: size.width, height: size.height)
  return NSAttributedString(attachment: attachment)
}

/// The small filled discs keep their shape at menu-bar font sizes.
final class FanIndicator {
  private var cachedCount = 0
  private var cachedSize: CGFloat = 0
  private var cachedColor: NSColor?
  private var cached: NSAttributedString?

  static func count(for speed: String?) -> Int {
    switch speed {
    case "LOW": return 1
    case "MID": return 2
    case "HIGH": return 3
    default: return 0
    }
  }

  func attachment(speed: String?, fontSize: CGFloat, color: NSColor) -> NSAttributedString? {
    let count = Self.count(for: speed)
    guard count > 0 else { return nil }
    if count == cachedCount, fontSize == cachedSize, color == cachedColor { return cached }
    let diameter = fontSize * 0.28
    let gap = fontSize * 0.05
    let size = NSSize(width: ceil(diameter + 2.5), height: fontSize)
    let image = NSImage(size: size, flipped: false) { rect in
      color.setFill()
      let stack = 3 * diameter + 2 * gap
      for i in 0..<count {
        let dot = NSRect(
          x: (rect.width - diameter) / 2,
          y: (rect.height - stack) / 2 + CGFloat(i) * (gap + diameter), width: diameter,
          height: diameter)
        NSBezierPath(ovalIn: dot).fill()
      }
      return true
    }
    let marker = NSTextAttachment()
    marker.image = image
    marker.bounds = NSRect(x: 0, y: -fontSize * 0.14, width: size.width, height: size.height)
    cached = NSAttributedString(attachment: marker)
    cachedCount = count
    cachedSize = fontSize
    cachedColor = color
    return cached
  }
}
