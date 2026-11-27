import AppKit

/// 메뉴 안에 넣는 "이름 ──●── 값" 슬라이더 한 줄
final class SliderMenuView: NSView {
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    var onChange: ((Int) -> Void)?

    init(title: String, value: Int, max: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 30, y: 6, width: 44, height: 16)
        slider.frame = NSRect(x: 76, y: 4, width: 154, height: 20)
        slider.minValue = 0
        slider.maxValue = Double(Swift.max(max, 1))
        slider.integerValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 232, y: 6, width: 36, height: 16)
        valueLabel.stringValue = "\(value)"
        [label, slider, valueLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        valueLabel.stringValue = "\(slider.integerValue)"
        onChange?(slider.integerValue)
    }
}
