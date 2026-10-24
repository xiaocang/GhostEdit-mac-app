import Foundation

enum SettingsValidationSupport {
    struct ValidationError: Error, Equatable {
        let title: String
        let message: String
    }

    struct ValidatedSettings: Equatable {
        let hotkeyKeyCode: UInt32
        let hotkeyModifiers: UInt32
        let model: String
        let historyLimit: Int
        let timeoutSeconds: Int
    }

    static func validateHotkeyKeyCode(_ keyCode: UInt32?) -> ValidationError? {
        if keyCode == nil {
            return ValidationError(
                title: "Hotkey key is required",
                message: "Choose a hotkey key before saving."
            )
        }
        return nil
    }

    static func validateModel(selectedOptionValue: String?, customModel: String) -> ValidationError? {
        if selectedOptionValue == nil && customModel.isEmpty {
            return ValidationError(
                title: "Model is required",
                message: "Choose a model or enter a custom model name."
            )
        }
        return nil
    }

    static func validateHotkeyModifiers(_ modifiers: UInt32) -> ValidationError? {
        if modifiers == 0 {
            return ValidationError(
                title: "Hotkey modifiers are required",
                message: "Select at least one modifier key (Command, Option, Control, or Shift)."
            )
        }
        return nil
    }

    static func validateHistoryLimit(_ text: String) -> Result<Int, ValidationError> {
        guard let limit = Int(text), limit > 0 else {
            return .failure(ValidationError(
                title: "History size is invalid",
                message: "Enter a whole number greater than 0 for History N."
            ))
        }
        return .success(limit)
    }

    static func validateTimeoutSeconds(_ text: String) -> Result<Int, ValidationError> {
        guard let seconds = Int(text), seconds >= 5 else {
            return .failure(ValidationError(
                title: "Timeout is invalid",
                message: "Enter a whole number of at least 5 for Timeout (seconds)."
            ))
        }
        return .success(seconds)
    }

    /// Run all validations in order, returning the first error or the validated settings.
    static func validateAll(
        hotkeyKeyCode: UInt32?,
        hotkeyModifiers: UInt32,
        selectedOptionValue: String?,
        customModel: String,
        historyLimitText: String,
        timeoutText: String
    ) -> Result<ValidatedSettings, ValidationError> {
        if let error = validateHotkeyKeyCode(hotkeyKeyCode) { return .failure(error) }
        if let error = validateModel(selectedOptionValue: selectedOptionValue, customModel: customModel) { return .failure(error) }
        if let error = validateHotkeyModifiers(hotkeyModifiers) { return .failure(error) }

        let historyLimit: Int
        switch validateHistoryLimit(historyLimitText) {
        case .success(let v): historyLimit = v
        case .failure(let e): return .failure(e)
        }
        let timeoutSeconds: Int
        switch validateTimeoutSeconds(timeoutText) {
        case .success(let v): timeoutSeconds = v
        case .failure(let e): return .failure(e)
        }

        return .success(ValidatedSettings(
            hotkeyKeyCode: hotkeyKeyCode!,
            hotkeyModifiers: hotkeyModifiers,
            model: customModel,
            historyLimit: historyLimit,
            timeoutSeconds: timeoutSeconds
        ))
    }

    /// Build hotkey modifier bitmask from individual checkbox states.
    static func buildHotkeyModifiers(command: Bool, option: Bool, control: Bool, shift: Bool) -> UInt32 {
        var modifiers: UInt32 = 0
        if command { modifiers |= (1 << 8) }
        if option { modifiers |= (1 << 11) }
        if control { modifiers |= (1 << 12) }
        if shift { modifiers |= (1 << 9) }
        return modifiers
    }

    /// Split a hotkey modifier bitmask into individual checkbox states.
    static func splitHotkeyModifiers(_ modifiers: UInt32) -> (command: Bool, option: Bool, control: Bool, shift: Bool) {
        return (
            command: (modifiers & (1 << 8)) != 0,
            option: (modifiers & (1 << 11)) != 0,
            control: (modifiers & (1 << 12)) != 0,
            shift: (modifiers & (1 << 9)) != 0
        )
    }
}
