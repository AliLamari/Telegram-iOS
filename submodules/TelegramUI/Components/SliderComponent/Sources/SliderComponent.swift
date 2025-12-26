import Foundation
import UIKit
import Display
import AsyncDisplayKit
import TelegramPresentationData
import LegacyComponents
import ComponentFlow
import GlassBackgroundComponent

public final class SliderComponent: Component {
    public final class Discrete: Equatable {
        public let valueCount: Int
        public let value: Int
        public let minValue: Int?
        public let markPositions: Bool
        public let valueUpdated: (Int) -> Void
        
        public init(valueCount: Int, value: Int, minValue: Int? = nil, markPositions: Bool, valueUpdated: @escaping (Int) -> Void) {
            self.valueCount = valueCount
            self.value = value
            self.minValue = minValue
            self.markPositions = markPositions
            self.valueUpdated = valueUpdated
        }
        
        public static func ==(lhs: Discrete, rhs: Discrete) -> Bool {
            if lhs.valueCount != rhs.valueCount {
                return false
            }
            if lhs.value != rhs.value {
                return false
            }
            if lhs.minValue != rhs.minValue {
                return false
            }
            if lhs.markPositions != rhs.markPositions {
                return false
            }
            return true
        }
    }
    
    public final class Continuous: Equatable {
        public let value: CGFloat
        public let minValue: CGFloat?
        public let valueUpdated: (CGFloat) -> Void
        
        public init(value: CGFloat, minValue: CGFloat? = nil, valueUpdated: @escaping (CGFloat) -> Void) {
            self.value = value
            self.minValue = minValue
            self.valueUpdated = valueUpdated
        }
        
        public static func ==(lhs: Continuous, rhs: Continuous) -> Bool {
            if lhs.value != rhs.value {
                return false
            }
            if lhs.minValue != rhs.minValue {
                return false
            }
            return true
        }
    }
    
    public enum Content: Equatable {
        case discrete(Discrete)
        case continuous(Continuous)
    }
    
    public let content: Content
    public let useNative: Bool
    public let trackBackgroundColor: UIColor
    public let trackForegroundColor: UIColor
    public let minTrackForegroundColor: UIColor?
    public let knobSize: CGFloat?
    public let knobColor: UIColor?
    public let isTrackingUpdated: ((Bool) -> Void)?
    
    public init(
        content: Content,
        useNative: Bool = false,
        trackBackgroundColor: UIColor,
        trackForegroundColor: UIColor,
        minTrackForegroundColor: UIColor? = nil,
        knobSize: CGFloat? = nil,
        knobColor: UIColor? = nil,
        isTrackingUpdated: ((Bool) -> Void)? = nil
    ) {
        self.content = content
        self.useNative = useNative
        self.trackBackgroundColor = trackBackgroundColor
        self.trackForegroundColor = trackForegroundColor
        self.minTrackForegroundColor = minTrackForegroundColor
        self.knobSize = knobSize
        self.knobColor = knobColor
        self.isTrackingUpdated = isTrackingUpdated
    }
    
    public static func ==(lhs: SliderComponent, rhs: SliderComponent) -> Bool {
        if lhs.content != rhs.content {
            return false
        }
        if lhs.trackBackgroundColor != rhs.trackBackgroundColor {
            return false
        }
        if lhs.trackForegroundColor != rhs.trackForegroundColor {
            return false
        }
        if lhs.minTrackForegroundColor != rhs.minTrackForegroundColor {
            return false
        }
        if lhs.knobSize != rhs.knobSize {
            return false
        }
        if lhs.knobColor != rhs.knobColor {
            return false
        }
        return true
    }
    
    final class SliderView: UISlider {
        var onTouchBegan: (() -> Void)?
        var onTouchEnded: (() -> Void)?
        
        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            onTouchBegan?()
            return super.beginTracking(touch, with: event)
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            onTouchEnded?()
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            onTouchEnded?()
        }
    }
    
    public final class View: UIView {
        private var nativeSliderView: SliderView?
        private var sliderView: TGPhotoEditorSliderView?
        private var customGlassSliderView: SliderView?
        private var glassKnob: LiquidGlassKnob?
        private var lastKnobPosition: CGFloat = 0.0
        private var lastKnobUpdateTime: CFTimeInterval = 0.0
        private var knobVelocity: CGFloat = 0.0
        private var component: SliderComponent?
        private weak var state: EmptyComponentState?
        
        public var hitTestTarget: UIView? {
            return self.sliderView
        }
        
        override public init(frame: CGRect) {
            super.init(frame: frame)
        }
        
        required public init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
                
        public func cancelGestures() {
            if let sliderView = self.sliderView, let gestureRecognizers = sliderView.gestureRecognizers {
                for gestureRecognizer in gestureRecognizers {
                    gestureRecognizer.isEnabled = false
                    gestureRecognizer.isEnabled = true
                }
            }
        }
        
        func update(component: SliderComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            self.component = component
            self.state = state
            
            let size = CGSize(width: availableSize.width, height: 44.0)
            
            if #available(iOS 26.0, *), component.useNative {
                let sliderView: SliderView
                if let current = self.nativeSliderView {
                    sliderView = current
                } else {
                    sliderView = SliderView()
                    sliderView.disablesInteractiveTransitionGestureRecognizer = true
                    sliderView.addTarget(self, action: #selector(self.sliderValueChanged), for: .valueChanged)
                    sliderView.layer.allowsGroupOpacity = true
                    
                    self.addSubview(sliderView)
                    self.nativeSliderView = sliderView
                    
                    switch component.content {
                    case let .continuous(continuous):
                        sliderView.minimumValue = Float(continuous.minValue ?? 0.0)
                        sliderView.maximumValue = 1.0
                    case let .discrete(discrete):
                        sliderView.minimumValue = 0.0
                        sliderView.maximumValue = Float(discrete.valueCount - 1)
                        sliderView.trackConfiguration = .init(numberOfTicks: discrete.valueCount)
                    }
                }
                switch component.content {
                case let .continuous(continuous):
                    sliderView.value = Float(continuous.value)
                case let .discrete(discrete):
                    sliderView.value = Float(discrete.value)
                }
                sliderView.minimumTrackTintColor = component.trackForegroundColor
                sliderView.maximumTrackTintColor = component.trackBackgroundColor
                
                transition.setFrame(view: sliderView, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: availableSize.width, height: 44.0)))
            } else if #available(iOS 13.0, *), component.useNative {
                // Custom Glass Slider (UISlider with LiquidGlassView knob - iOS 13-25)
                let customSliderView: SliderView
                let knobSize: CGFloat = component.knobSize ?? 28.0
                
                if let current = self.customGlassSliderView {
                    customSliderView = current
                } else {
                    customSliderView = SliderView()
                    customSliderView.disablesInteractiveTransitionGestureRecognizer = true
                    customSliderView.addTarget(self, action: #selector(self.sliderValueChanged), for: .valueChanged)
                    customSliderView.layer.allowsGroupOpacity = true
                    
                    switch component.content {
                    case let .continuous(continuous):
                        customSliderView.minimumValue = Float(continuous.minValue ?? 0.0)
                        customSliderView.maximumValue = 1.0
                    case let .discrete(discrete):
                        customSliderView.minimumValue = 0.0
                        customSliderView.maximumValue = Float(discrete.valueCount - 1)
                    }

                    customSliderView.setThumbImage(UIImage(), for: .normal)
                    customSliderView.setThumbImage(UIImage(), for: .highlighted)
                    
                    self.addSubview(customSliderView)
                    self.customGlassSliderView = customSliderView

                    let knobConfig = LiquidGlassKnob.Configuration(
                        size: knobSize,
                        isDark: false
                    )
                    let glassKnob = LiquidGlassKnob(configuration: knobConfig)
                    self.glassKnob = glassKnob

                    self.addSubview(glassKnob)
                }
                
                customSliderView.onTouchBegan = { [weak self, weak glassKnob] in
                    guard let self = self, let glassKnob = glassKnob else { return }
                    self.lastKnobUpdateTime = CACurrentMediaTime()
                    glassKnob.setActive(true)
                }
                
                customSliderView.onTouchEnded = { [weak self, weak glassKnob] in
                    guard let self = self, let glassKnob = glassKnob else { return }
                    self.knobVelocity = 0.0
                    glassKnob.setSqueeze(1.0)
                    glassKnob.setActive(false)
                }
                
                switch component.content {
                case let .continuous(continuous):
                    customSliderView.value = Float(continuous.value)
                case let .discrete(discrete):
                    customSliderView.value = Float(discrete.value)
                }
                
                customSliderView.minimumTrackTintColor = component.trackForegroundColor
                customSliderView.maximumTrackTintColor = component.trackBackgroundColor

                if let glassKnob = self.glassKnob {
                    let sliderFrame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: availableSize.width, height: 44.0))
                    let trackRect = customSliderView.trackRect(forBounds: sliderFrame)
                    let thumbRect = customSliderView.thumbRect(forBounds: sliderFrame, trackRect: trackRect, value: customSliderView.value)
                    glassKnob.center = CGPoint(x: thumbRect.midX, y: thumbRect.midY)
                }
                
                transition.setFrame(view: customSliderView, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: availableSize.width, height: 44.0)))
            } else {
                var internalIsTrackingUpdated: ((Bool) -> Void)?
                if let isTrackingUpdated = component.isTrackingUpdated {
                    internalIsTrackingUpdated = { [weak self] isTracking in
                        if let self {
                            if !"".isEmpty {
                                if isTracking {
                                    self.sliderView?.bordered = true
                                } else {
                                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1, execute: { [weak self] in
                                        self?.sliderView?.bordered = false
                                    })
                                }
                            }
                        }
                        isTrackingUpdated(isTracking)
                    }
                }
                
                let sliderView: TGPhotoEditorSliderView
                if let current = self.sliderView {
                    sliderView = current
                } else {
                    sliderView = TGPhotoEditorSliderView()
                    sliderView.enablePanHandling = true
                    if let knobSize = component.knobSize {
                        sliderView.lineSize = knobSize + 4.0
                    } else {
                        sliderView.lineSize = 4.0
                    }
                    sliderView.trackCornerRadius = sliderView.lineSize * 0.5
                    sliderView.dotSize = 5.0
                    sliderView.minimumValue = 0.0
                    sliderView.startValue = 0.0
                    sliderView.disablesInteractiveTransitionGestureRecognizer = true
                    
                    switch component.content {
                    case let .discrete(discrete):
                        sliderView.maximumValue = CGFloat(discrete.valueCount - 1)
                        sliderView.positionsCount = discrete.valueCount
                        sliderView.useLinesForPositions = true
                        sliderView.markPositions = discrete.markPositions
                    case .continuous:
                        sliderView.maximumValue = 1.0
                    }
                    
                    sliderView.backgroundColor = nil
                    sliderView.isOpaque = false
                    sliderView.backColor = component.trackBackgroundColor
                    sliderView.startColor = component.trackBackgroundColor
                    sliderView.trackColor = component.trackForegroundColor
                    if let knobSize = component.knobSize {
                        sliderView.knobImage = generateImage(CGSize(width: 40.0, height: 40.0), rotatedContext: { size, context in
                            context.clear(CGRect(origin: CGPoint(), size: size))
                            context.setShadow(offset: CGSize(width: 0.0, height: -3.0), blur: 12.0, color: UIColor(white: 0.0, alpha: 0.25).cgColor)
                            if let knobColor = component.knobColor {
                                context.setFillColor(knobColor.cgColor)
                            } else {
                                context.setFillColor(UIColor.white.cgColor)
                            }
                            context.fillEllipse(in: CGRect(origin: CGPoint(x: floor((size.width - knobSize) * 0.5), y: floor((size.width - knobSize) * 0.5)), size: CGSize(width: knobSize, height: knobSize)))
                        })
                    } else {
                        sliderView.knobImage = generateImage(CGSize(width: 40.0, height: 40.0), rotatedContext: { size, context in
                            context.clear(CGRect(origin: CGPoint(), size: size))
                            context.setShadow(offset: CGSize(width: 0.0, height: -3.0), blur: 12.0, color: UIColor(white: 0.0, alpha: 0.25).cgColor)
                            context.setFillColor(UIColor.white.cgColor)
                            context.fillEllipse(in: CGRect(origin: CGPoint(x: 6.0, y: 6.0), size: CGSize(width: 28.0, height: 28.0)))
                        })
                    }
                    
                    sliderView.frame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: size)
                    sliderView.hitTestEdgeInsets = UIEdgeInsets(top: -sliderView.frame.minX, left: 0.0, bottom: 0.0, right: -sliderView.frame.minX)
                    
                    
                    sliderView.disablesInteractiveTransitionGestureRecognizer = true
                    sliderView.addTarget(self, action: #selector(self.sliderValueChanged), for: .valueChanged)
                    sliderView.layer.allowsGroupOpacity = true
                    self.sliderView = sliderView
                    self.addSubview(sliderView)
                }
                sliderView.lowerBoundTrackColor = component.minTrackForegroundColor
                switch component.content {
                case let .discrete(discrete):
                    sliderView.value = CGFloat(discrete.value)
                    if let minValue = discrete.minValue {
                        sliderView.lowerBoundValue = CGFloat(minValue)
                    } else {
                        sliderView.lowerBoundValue = 0.0
                    }
                case let .continuous(continuous):
                    sliderView.value = continuous.value
                    if let minValue = continuous.minValue {
                        sliderView.lowerBoundValue = minValue
                    } else {
                        sliderView.lowerBoundValue = 0.0
                    }
                }
                sliderView.interactionBegan = {
                    internalIsTrackingUpdated?(true)
                }
                sliderView.interactionEnded = {
                    internalIsTrackingUpdated?(false)
                }
                
                transition.setFrame(view: sliderView, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: availableSize.width, height: 44.0)))
                sliderView.hitTestEdgeInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
            }
            
            return size
        }
        
        @objc private func sliderValueChanged() {
            guard let component = self.component else {
                return
            }

            if let customSliderView = self.customGlassSliderView, let glassKnob = self.glassKnob {
                let sliderFrame = customSliderView.frame
                let trackRect = customSliderView.trackRect(forBounds: sliderFrame)
                let thumbRect = customSliderView.thumbRect(forBounds: sliderFrame, trackRect: trackRect, value: customSliderView.value)
                let newPosition = thumbRect.midX

                let currentTime = CACurrentMediaTime()
                let timeDelta = currentTime - lastKnobUpdateTime
                if timeDelta > 0 {
                    let positionDelta = abs(newPosition - lastKnobPosition)
                    knobVelocity = positionDelta / CGFloat(timeDelta)
                }
                lastKnobPosition = newPosition
                lastKnobUpdateTime = currentTime

                let maxVelocity: CGFloat = 600.0
                let velocityFactor = min(knobVelocity / maxVelocity, 1.0)
                let squeeze = 1.0 - (velocityFactor * 0.3)

                glassKnob.center = CGPoint(x: thumbRect.midX, y: thumbRect.midY)
                glassKnob.setSqueeze(squeeze)

                glassKnob.renderNow()
            }

            let floatValue: CGFloat
            if let sliderView = self.sliderView {
                floatValue = sliderView.value
            } else if let nativeSliderView = self.nativeSliderView {
                floatValue = CGFloat(nativeSliderView.value)
            } else if let customGlassSliderView = self.customGlassSliderView {
                floatValue = CGFloat(customGlassSliderView.value)
            } else {
                return
            }

            switch component.content {
            case let .discrete(discrete):
                discrete.valueUpdated(Int(floatValue))
            case let .continuous(continuous):
                continuous.valueUpdated(floatValue)
            }
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }
    
    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
