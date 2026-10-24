import XCTest
@testable import GhostEditCore

final class SettingsValidationSupportTests: XCTestCase {

    // MARK: - validateHotkeyKeyCode

    func testHotkeyKeyCodeNilFails() {
        let error = SettingsValidationSupport.validateHotkeyKeyCode(nil)
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.title, "Hotkey key is required")
    }

    func testHotkeyKeyCodeValidPasses() {
        XCTAssertNil(SettingsValidationSupport.validateHotkeyKeyCode(14))
    }

    // MARK: - validateModel

    func testModelBothNilFails() {
        let error = SettingsValidationSupport.validateModel(selectedOptionValue: nil, customModel: "")
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.title, "Model is required")
    }

    func testModelWithSelectedOptionPasses() {
        XCTAssertNil(SettingsValidationSupport.validateModel(selectedOptionValue: "gpt-4", customModel: ""))
    }

    func testModelWithCustomModelPasses() {
        XCTAssertNil(SettingsValidationSupport.validateModel(selectedOptionValue: nil, customModel: "custom-model"))
    }

    func testModelBothProvidedPasses() {
        XCTAssertNil(SettingsValidationSupport.validateModel(selectedOptionValue: "gpt-4", customModel: "custom"))
    }

    // MARK: - validateHotkeyModifiers

    func testHotkeyModifiersZeroFails() {
        let error = SettingsValidationSupport.validateHotkeyModifiers(0)
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.title, "Hotkey modifiers are required")
    }

    func testHotkeyModifiersNonZeroPasses() {
        XCTAssertNil(SettingsValidationSupport.validateHotkeyModifiers(256))
    }

    // MARK: - validateHistoryLimit

    func testHistoryLimitValid() {
        if case .success(let v) = SettingsValidationSupport.validateHistoryLimit("100") {
            XCTAssertEqual(v, 100)
        } else { XCTFail("Expected success") }
    }

    func testHistoryLimitZeroFails() {
        if case .failure(let e) = SettingsValidationSupport.validateHistoryLimit("0") {
            XCTAssertEqual(e.title, "History size is invalid")
        } else { XCTFail("Expected failure") }
    }

    func testHistoryLimitNegativeFails() {
        if case .failure = SettingsValidationSupport.validateHistoryLimit("-5") {
        } else { XCTFail("Expected failure") }
    }

    func testHistoryLimitNonNumericFails() {
        if case .failure = SettingsValidationSupport.validateHistoryLimit("abc") {
        } else { XCTFail("Expected failure") }
    }

    func testHistoryLimitEmptyFails() {
        if case .failure = SettingsValidationSupport.validateHistoryLimit("") {
        } else { XCTFail("Expected failure") }
    }

    // MARK: - validateTimeoutSeconds

    func testTimeoutValid() {
        if case .success(let v) = SettingsValidationSupport.validateTimeoutSeconds("30") {
            XCTAssertEqual(v, 30)
        } else { XCTFail("Expected success") }
    }

    func testTimeoutBoundary() {
        if case .success(let v) = SettingsValidationSupport.validateTimeoutSeconds("5") {
            XCTAssertEqual(v, 5)
        } else { XCTFail("Expected success") }
    }

    func testTimeoutTooLowFails() {
        if case .failure(let e) = SettingsValidationSupport.validateTimeoutSeconds("4") {
            XCTAssertEqual(e.title, "Timeout is invalid")
        } else { XCTFail("Expected failure") }
    }

    func testTimeoutNonNumericFails() {
        if case .failure = SettingsValidationSupport.validateTimeoutSeconds("abc") {
        } else { XCTFail("Expected failure") }
    }

    // MARK: - validateAll

    func testValidateAllSuccess() {
        let result = SettingsValidationSupport.validateAll(
            hotkeyKeyCode: 14, hotkeyModifiers: 256,
            selectedOptionValue: "model", customModel: "claude-3",
            historyLimitText: "100", timeoutText: "30"
        )
        if case .success(let settings) = result {
            XCTAssertEqual(settings.hotkeyKeyCode, 14)
            XCTAssertEqual(settings.hotkeyModifiers, 256)
            XCTAssertEqual(settings.model, "claude-3")
            XCTAssertEqual(settings.historyLimit, 100)
            XCTAssertEqual(settings.timeoutSeconds, 30)
        } else { XCTFail("Expected success") }
    }

    func testValidateAllFailsOnFirstError() {
        let result = SettingsValidationSupport.validateAll(
            hotkeyKeyCode: nil, hotkeyModifiers: 256,
            selectedOptionValue: "model", customModel: "claude-3",
            historyLimitText: "100", timeoutText: "30"
        )
        if case .failure(let error) = result {
            XCTAssertEqual(error.title, "Hotkey key is required")
        } else { XCTFail("Expected failure") }
    }

    func testValidateAllFailsOnTimeout() {
        let result = SettingsValidationSupport.validateAll(
            hotkeyKeyCode: 14, hotkeyModifiers: 256,
            selectedOptionValue: "model", customModel: "claude-3",
            historyLimitText: "100", timeoutText: "2"
        )
        if case .failure(let error) = result {
            XCTAssertEqual(error.title, "Timeout is invalid")
        } else { XCTFail("Expected failure") }
    }

    // MARK: - buildHotkeyModifiers / splitHotkeyModifiers

    func testBuildModifiersCommand() {
        let m = SettingsValidationSupport.buildHotkeyModifiers(command: true, option: false, control: false, shift: false)
        XCTAssertEqual(m, 1 << 8)
    }

    func testBuildModifiersOption() {
        let m = SettingsValidationSupport.buildHotkeyModifiers(command: false, option: true, control: false, shift: false)
        XCTAssertEqual(m, 1 << 11)
    }

    func testBuildModifiersControl() {
        let m = SettingsValidationSupport.buildHotkeyModifiers(command: false, option: false, control: true, shift: false)
        XCTAssertEqual(m, 1 << 12)
    }

    func testBuildModifiersShift() {
        let m = SettingsValidationSupport.buildHotkeyModifiers(command: false, option: false, control: false, shift: true)
        XCTAssertEqual(m, 1 << 9)
    }

    func testBuildModifiersAll() {
        let m = SettingsValidationSupport.buildHotkeyModifiers(command: true, option: true, control: true, shift: true)
        XCTAssertEqual(m, (1 << 8) | (1 << 11) | (1 << 12) | (1 << 9))
    }

    func testBuildModifiersNone() {
        let m = SettingsValidationSupport.buildHotkeyModifiers(command: false, option: false, control: false, shift: false)
        XCTAssertEqual(m, 0)
    }

    func testSplitModifiersRoundTrip() {
        let m = SettingsValidationSupport.buildHotkeyModifiers(command: true, option: false, control: true, shift: false)
        let (command, option, control, shift) = SettingsValidationSupport.splitHotkeyModifiers(m)
        XCTAssertTrue(command)
        XCTAssertFalse(option)
        XCTAssertTrue(control)
        XCTAssertFalse(shift)
    }

    func testSplitModifiersZero() {
        let (command, option, control, shift) = SettingsValidationSupport.splitHotkeyModifiers(0)
        XCTAssertFalse(command)
        XCTAssertFalse(option)
        XCTAssertFalse(control)
        XCTAssertFalse(shift)
    }

    func testSplitModifiersAll() {
        let all = SettingsValidationSupport.buildHotkeyModifiers(command: true, option: true, control: true, shift: true)
        let (command, option, control, shift) = SettingsValidationSupport.splitHotkeyModifiers(all)
        XCTAssertTrue(command)
        XCTAssertTrue(option)
        XCTAssertTrue(control)
        XCTAssertTrue(shift)
    }
}
