import AppKit

final class VisualEffectsPageController: SettingsPageController {
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let configuration = NSView()
    private var configuredEffect: StaticEffect?
    private var configurationSliders: [PreferenceSlider] = []
    private weak var fireplaceToggle: ActionButton?
    private weak var fireplaceWidthSlider: PreferenceSlider?
    private weak var fireplaceHeightSlider: PreferenceSlider?
    private weak var fireplaceOffsetSlider: PreferenceSlider?
    private weak var decorationsToggle: ActionButton?
    private weak var lightsToggle: ActionButton?
    private var fireToggles: [PreferenceKey: ActionButton] = [:]

    override func build() {
        let prefs = context.preferences
        let effects = card("Move/Resize")
        toggle("Show Corner Hints", key: .hints, id: "window.feedback.cornerHints", description: "Mark the selected corner once Command + right-button resizing starts. Animated corners use your selected resize effect; static markers use your system accent colour.", keywords: ["overlay", "highlight", "corner", "hint", "neon", "glow", "accent", "colour"], section: "Move/Resize", to: effects)
        let animated = ActionButton("Animated effects") {}; animated.setButtonType(.switch)
        animated.handler = { [weak animated] in prefs.set(animated?.state == .on, for: .animatedEffects) }
        let motionNote = UI.caption("Disabled because Reduce Motion is enabled in System Settings.")
        add(UI.horizontal([animated, motionNote]), to: effects)
        add(UI.caption("Animate the effects selected in this section, including their gradual departures. Turn off for a steady corner marker and a simple moving outline."), to: effects)
        metadata(animated, id: "window.feedback.animatedEffects", label: "Animated Effects", description: "Animate your selected resize and move effects and their gradual departures. Reduce Motion uses static visuals and preserves your saved preferences.", keywords: ["fire", "flame", "fog", "mist", "lightning", "wind", "animation", "reduce motion"], section: "Move/Resize", unavailable: "Disabled because Reduce Motion is enabled in System Settings.")
        let refreshMotion = { [weak self, weak animated, weak motionNote] in
            let reduced = self?.reduceMotion() ?? true
            animated?.isEnabled = !reduced
            animated?.state = !reduced && prefs.bool(.animatedEffects) ? .on : .off
            motionNote?.isHidden = !reduced
        }
        refreshers.append(refreshMotion)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionSettingsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        toggle("Show Window Outline", key: .outline, id: "window.feedback.frame", description: "Outline the actual accepted window frame while resizing or moving.", keywords: ["overlay", "border", "frame", "outline"], section: "Move/Resize", to: effects)
        effectControls(resizing: true, to: effects)
        effectControls(resizing: false, to: effects)
        toggle("Show effects for normal window drags", key: .normalWindowEffects, id: "visualEffects.normalWindowDrags",
               description: "Also show your chosen effects when you drag a window by its title bar or resize it from an edge with the left mouse button. Normal mouse input passes through unchanged.",
               keywords: ["normal", "ordinary", "title bar", "edge", "drag", "resize", "move", "left mouse"], section: "Move/Resize", to: effects)
        let ambient = card("Static")
        let picker = ActionPopup(items: StaticEffect.allCases.map(\.title)) { index in
            prefs.set(StaticEffect.allCases[index].rawValue, for: .staticEffect)
        }
        add(UI.horizontal([UI.label("Effect"), NSView(), picker]), to: ambient)
        metadata(picker, id: "visualEffects.static.effect", label: "Static Effect", description: "Keep an effect running across all screens until No Effect is selected. Snow Storm and Fire Storm have their own controls.", keywords: StaticEffect.allCases.map(\.title) + ["ambient", "continuous", "desktop", "fireplace", "hearth", "embers", "flames"], section: "Static", value: { prefs.staticEffect.title })
        configuration.identifier = NSUserInterfaceItemIdentifier("visualEffects.static.configuration")
        configuration.wantsLayer = true
        configuration.layer?.cornerRadius = 6
        configuration.layer?.borderWidth = 0.5
        configuration.layer?.borderColor = NSColor.separatorColor.cgColor
        add(configuration, to: ambient)
        configuration.heightAnchor.constraint(equalToConstant: 320).isActive = true
        add(UI.caption("Runs behind the frontmost window on each display and lets clicks pass through. Suspend All, Reduce Motion, and sleep pause these effects."), to: ambient)
        refreshers.append { [weak self, weak picker] in
            picker?.selectItem(at: StaticEffect.allCases.firstIndex(of: prefs.staticEffect) ?? 0)
            self?.refreshConfiguration()
        }
    }

    private func refreshConfiguration() {
        let effect = context.preferences.staticEffect
        guard configuredEffect != effect else {
            configurationSliders.forEach { $0.refresh() }
            fireplaceToggle?.state = context.preferences.bool(.stormFireplace) ? .on : .off
            fireplaceWidthSlider?.slider.isEnabled = context.preferences.bool(.stormFireplace)
            fireplaceHeightSlider?.slider.isEnabled = context.preferences.bool(.stormFireplace)
            fireplaceOffsetSlider?.slider.isEnabled = context.preferences.bool(.stormFireplace)
            decorationsToggle?.state = context.preferences.bool(.stormDecorations) ? .on : .off
            lightsToggle?.state = context.preferences.bool(.stormLights) ? .on : .off
            for (key, button) in fireToggles { button.state = context.preferences.bool(key) ? .on : .off }
            return
        }
        configuredEffect = effect
        fireplaceToggle = nil
        fireplaceWidthSlider = nil
        fireplaceHeightSlider = nil
        fireplaceOffsetSlider = nil
        decorationsToggle = nil; lightsToggle = nil
        fireToggles.removeAll()
        configurationSliders.removeAll()
        configuration.subviews.forEach { $0.removeFromSuperview() }
        // Remove metadata for the old effect so search never opens hidden controls.
        controls = controls.filter { !$0.key.hasPrefix("visualEffects.static.option.") }
        context.catalog.remove { $0.id.hasPrefix("visualEffects.static.option.") }
        guard effect != .none else {
            let title = UI.label("No effect selected", weight: .semibold)
            let hint = UI.caption("Choose an effect for options to play with.")
            let empty = UI.vertical([title, hint], spacing: 6)
            empty.alignment = .centerX
            empty.identifier = NSUserInterfaceItemIdentifier("visualEffects.static.empty")
            empty.translatesAutoresizingMaskIntoConstraints = false
            configuration.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: configuration.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: configuration.centerYAnchor)
            ])
            return
        }
        let content = UI.vertical([], spacing: effect == .fireStorm ? 8 : 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        configuration.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: configuration.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: configuration.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: configuration.topAnchor, constant: 16)
        ])
        var snowFireplaceSize: (width: PreferenceSlider, height: PreferenceSlider, offset: PreferenceSlider)?
        if effect == .snowStorm {
            let prefs = context.preferences
            let fireplace = ActionButton("Fireplace") {}; fireplace.setButtonType(.switch)
            fireplace.state = prefs.bool(.stormFireplace) ? .on : .off
            let fireplaceWidth = PreferenceSlider(preferences: prefs, key: .stormFireplaceWidth)
            let fireplaceHeight = PreferenceSlider(preferences: prefs, key: .stormFireplaceHeight)
            let fireplaceOffset = PreferenceSlider(preferences: prefs, key: .stormFireplaceOffset)
            fireplaceWidth.slider.isEnabled = prefs.bool(.stormFireplace)
            fireplaceHeight.slider.isEnabled = prefs.bool(.stormFireplace)
            fireplaceOffset.slider.isEnabled = prefs.bool(.stormFireplace)
            fireplace.handler = { [weak fireplace, weak fireplaceWidth, weak fireplaceHeight, weak fireplaceOffset] in
                let enabled = fireplace?.state == .on
                prefs.set(enabled, for: .stormFireplace)
                fireplaceWidth?.slider.isEnabled = enabled
                fireplaceHeight?.slider.isEnabled = enabled
                fireplaceOffset?.slider.isEnabled = enabled
            }
            fireplaceToggle = fireplace
            fireplaceWidthSlider = fireplaceWidth
            fireplaceHeightSlider = fireplaceHeight
            fireplaceOffsetSlider = fireplaceOffset
            snowFireplaceSize = (fireplaceWidth, fireplaceHeight, fireplaceOffset)
            let decorations = ActionButton("") {}; decorations.setButtonType(.switch)
            decorations.setAccessibilityLabel("Decorations")
            decorations.state = prefs.bool(.stormDecorations) ? .on : .off
            decorations.handler = { [weak decorations] in prefs.set(decorations?.state == .on, for: .stormDecorations) }
            decorationsToggle = decorations
            let decorationsLabel = UI.label("Decorations")
            decorationsLabel.identifier = NSUserInterfaceItemIdentifier("visualEffects.static.decorationsLabel")
            let santaGesture = NSClickGestureRecognizer(target: self, action: #selector(summonSanta(_:)))
            santaGesture.numberOfClicksRequired = 2
            decorationsLabel.addGestureRecognizer(santaGesture)
            let decorationsControl = UI.horizontal([decorations, decorationsLabel], spacing: 2)
            let lights = ActionButton("") {}; lights.setButtonType(.switch)
            lights.setAccessibilityLabel("Lights")
            lights.state = prefs.bool(.stormLights) ? .on : .off
            lights.handler = { [weak lights] in prefs.set(lights?.state == .on, for: .stormLights) }
            lightsToggle = lights
            let lightsLabel = UI.label("Lights")
            lightsLabel.identifier = NSUserInterfaceItemIdentifier("visualEffects.static.lightsLabel")
            let yetiGesture = NSClickGestureRecognizer(target: self, action: #selector(summonYeti(_:)))
            yetiGesture.numberOfClicksRequired = 2
            lightsLabel.addGestureRecognizer(yetiGesture)
            let lightsControl = UI.horizontal([lights, lightsLabel], spacing: 2)
            add(UI.horizontal([UI.label(effect.title, weight: .semibold), NSView(), fireplace, decorationsControl, lightsControl], spacing: 16), to: content)
            metadata(fireplace, id: "visualEffects.static.option.fireplace", label: "Fireplace", description: "Build an open-bottom fireplace behind the Dock with irregular flames. It starts wider than the Dock and grows to fit magnification and extra icons. Bricks fly in; turning it off disperses it into smoke. Clicks pass through.", keywords: ["snow storm", "hearth", "bricks", "wood", "flame", "dock", "magnification", "smoke"], section: "Static", value: { prefs.bool(.stormFireplace) ? "On" : "Off" })
            metadata(fireplaceWidth.slider, id: "visualEffects.static.option.fireplaceWidth", label: "Fireplace Width", description: "Choose 30% to 80% of the display width for the fireplace, or the display height for a side Dock. The surround can grow farther when needed to contain the Dock and its magnified icons.", keywords: ["fireplace", "width", "size", "dock", "screen"], section: "Static", value: { [weak fireplaceWidth] in fireplaceWidth?.valueText })
            metadata(fireplaceHeight.slider, id: "visualEffects.static.option.fireplaceHeight", label: "Fireplace Height", description: "Set the fireplace height from 80 to 320 points, independently of the Dock size.", keywords: ["fireplace", "height", "size", "screen"], section: "Static", value: { [weak fireplaceHeight] in fireplaceHeight?.valueText })
            metadata(fireplaceOffset.slider, id: "visualEffects.static.option.fireplaceOffset", label: "Fireplace Offset", description: "Move the fireplace across the display. The centre tick snaps to zero; each end places the fireplace at the screen edge. For a side Dock, this moves it vertically.", keywords: ["fireplace", "offset", "position", "centre", "center", "left", "right"], section: "Static", value: { [weak fireplaceOffset] in fireplaceOffset?.valueText })
            metadata(decorations, id: "visualEffects.static.option.decorations", label: "Decorations", description: "Show trees, presents, snowmen, and carolers on normal app windows whenever Snow Storm runs.", keywords: ["christmas", "tree", "presents", "snowman", "carolers"], section: "Static", value: { prefs.bool(.stormDecorations) ? "On" : "Off" })
            metadata(lights, id: "visualEffects.static.option.lights", label: "Lights", description: "Hang old-style incandescent bulbs on green wire below the top edge of normal app windows whenever Snow Storm runs.", keywords: ["christmas", "bulbs", "window lights", "holiday", "incandescent"], section: "Static", value: { prefs.bool(.stormLights) ? "On" : "Off" })
        } else if effect == .fireStorm {
            let prefs = context.preferences
            func fireToggle(_ title: String, key: PreferenceKey, id: String, description: String) -> ActionButton {
                let button = ActionButton(title) {}; button.setButtonType(.switch)
                button.state = prefs.bool(key) ? .on : .off
                button.handler = { [weak button] in prefs.set(button?.state == .on, for: key) }
                fireToggles[key] = button
                metadata(button, id: "visualEffects.static.option." + id, label: title,
                         description: description, keywords: ["fire storm", "flames", "embers", title],
                         section: "Static", value: { prefs.bool(key) ? "On" : "Off" })
                return button
            }
            let smoke = fireToggle("Smoke", key: .fireSmoke, id: "smoke",
                description: "Add drifting smoke plumes rising from the flames.")
            let ash = fireToggle("Falling ash", key: .fireAsh, id: "fallingAsh",
                description: "Mix grey ash flakes into the falling ember storm.")
            let glow = fireToggle("Heat glow", key: .fireHeatGlow, id: "heatGlow",
                description: "Add soft, rising orange heat glows above the flames.")
            add(UI.horizontal([UI.label(effect.title, weight: .semibold), NSView(), smoke, ash, glow], spacing: 12), to: content)
            add(UI.caption("Embers can ignite window tops. Each flare burns out and releases smoke. The storm stays behind the frontmost window."), to: content)
        } else {
            add(UI.label(effect.title, weight: .semibold), to: content)
            if effect == .rain {
                add(UI.caption("Splash frequency is the chance that a drop splashes when it hits a window top."), to: content)
            }
        }
        for (label, key) in effect.options {
            let slider = PreferenceSlider(preferences: context.preferences, key: key)
            configurationSliders.append(slider)
            add(UI.horizontal([UI.label(label), NSView(), slider]), to: content)
            let description = key == .fireIgnitionChance ?
                "Chance that a falling ember ignites an eligible window top it hits. 0% never ignites; 100% always ignites when a fire slot is available." : key == .rainSplashFrequency ?
                "Set the percentage chance that a raindrop splashes when it hits a window top. 0% never splashes; 100% always splashes." :
                "Adjust \(effect.title.lowercased()) \(label.lowercased()). Changes apply immediately and are saved for this effect."
            metadata(slider.slider, id: "visualEffects.static.option." + label.lowercased().replacingOccurrences(of: " ", with: ""), label: label, description: description, keywords: [effect.title, "amount", "speed", "size"], section: "Static", value: { [weak slider] in slider?.valueText })
        }
        if let snowFireplaceSize {
            configurationSliders.append(contentsOf: [snowFireplaceSize.width, snowFireplaceSize.height, snowFireplaceSize.offset])
            add(UI.horizontal([UI.label("Fireplace Width"), NSView(), snowFireplaceSize.width]), to: content)
            add(UI.horizontal([UI.label("Fireplace Height"), NSView(), snowFireplaceSize.height]), to: content)
            add(UI.horizontal([UI.label("Fireplace Offset"), NSView(), snowFireplaceSize.offset]), to: content)
            add(UI.caption("Snow forms uneven banks up to 24 points on windows and 12 on the cursor. Edge snow can spill; quick shaking sheds more. Snowfall intensity changes density and fall speed. Wind gusts controls sideways bursts and occasional edge vortices."), to: content)
        }
    }
    @objc private func summonSanta(_ sender: Any) { context.preferences.requestSanta() }
    @objc private func summonYeti(_ sender: Any) { context.preferences.requestYeti() }

    private func effectControls(resizing: Bool, to parent: NSStackView) {
        let prefs = context.preferences
        let section = "Move/Resize"
        let prefix = resizing ? "window.resize" : "window.move"
        let effectKey: PreferenceKey = resizing ? .resizeEffect : .moveEffect
        let options = resizing ? WindowEffect.resizeOptions : WindowEffect.moveOptions
        add(UI.label(resizing ? "Resize effects" : "Move effects", weight: .semibold), to: parent)
        add(UI.caption(resizing ? "Choose an effect for Command + right-button resizing, or No Effect. The normal-drag option below also uses this choice." :
                           "Choose an effect for Command + left-button moving, or No Effect. The normal-drag option below also uses this choice."), to: parent)
        let popup = ActionPopup(items: options.map(\.title)) { index in prefs.set(options[index].rawValue, for: effectKey) }
        add(UI.horizontal([UI.label("Effect"), NSView(), popup]), to: parent)
        metadata(popup, id: prefix + ".effect", label: resizing ? "Resize Effect" : "Move Effect", description: options.map(\.title).joined(separator: ", ") + ". Selection is saved independently for this gesture.", keywords: ["visual", "animation", "style", "effect"] + options.map(\.title), section: section,
                 value: { WindowEffect(rawValue: prefs.string(effectKey))?.title })
        refreshers.append { [weak popup] in
            popup?.selectItem(at: options.firstIndex { $0.rawValue == prefs.string(effectKey) } ?? 0)
        }
    }
    @objc private func motionSettingsChanged() { refreshValues() }
}

private final class PreferenceSlider: NSView {
    let slider = NSSlider()
    private let value = UI.caption("")
    private let preferences: PreferenceStore
    private let key: PreferenceKey
    var valueText: String {
        let amount = preferences.int(key)
        return "\(key == .stormFireplaceOffset && amount > 0 ? "+" : "")\(amount)\(key == .stormFireplaceHeight ? " pt" : "%")"
    }
    init(preferences: PreferenceStore, key: PreferenceKey) {
        self.preferences = preferences; self.key = key
        super.init(frame: .zero)
        slider.minValue = Double(key.range?.lowerBound ?? 1)
        slider.maxValue = Double(key.range?.upperBound ?? 100)
        slider.isContinuous = true
        if key == .stormFireplaceOffset {
            slider.numberOfTickMarks = 3
            slider.allowsTickMarkValuesOnly = false
        }
        slider.target = self; slider.action = #selector(changed)
        let row = UI.horizontal([slider, value]); UI.pin(row, in: self)
        widthAnchor.constraint(equalToConstant: 230).isActive = true
        value.widthAnchor.constraint(equalToConstant: key == .stormFireplaceHeight || key == .stormFireplaceOffset ? 48 : 34).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic interface") }
    func refresh() { slider.integerValue = preferences.int(key); value.stringValue = valueText }
    @objc private func changed() {
        let selected = slider.integerValue
        preferences.set(key == .stormFireplaceOffset && abs(selected) <= 6 ? 0 : selected, for: key)
        refresh()
    }
}
