import AppKit

/// A private window-server space with an absolute level, like Alcove's `SpaceManager`.
///
/// Window levels only order windows *within* a space. Alcove moves its notch panels into their own
/// space at absolute level 400 (`CGSSpaceCreate` + `CGSSpaceSetAbsoluteLevel`), which puts them
/// above every normal window whatever its level, including ours. The island joins a space one
/// level higher so it covers Alcove's pill instead of the other way round. The same trick keeps it
/// visible over full-screen apps.
///
/// The CGS calls are private SkyLight API, looked up at runtime so a missing symbol only means
/// falling back to the plain window level.
@MainActor
final class WindowSpace {
    /// Alcove uses 400 (`mov w0, #0x190` before `SpaceManager.init`).
    nonisolated static let islandLevel: Int32 = 401

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpacesWindows = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias Spaces = @convention(c) (Int32, CFArray) -> Void
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void

    private struct API {
        let connection: MainConnectionID
        let create: SpaceCreate
        let setLevel: SpaceSetAbsoluteLevel
        let addWindows: SpacesWindows
        let removeWindows: SpacesWindows
        let show: Spaces
        let destroy: SpaceDestroy

        static let shared: API? = {
            let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
                ?? dlopen(nil, RTLD_LAZY)
            func load<T>(_ name: String, as _: T.Type) -> T? {
                guard let symbol = dlsym(handle, name) else { return nil }
                return unsafeBitCast(symbol, to: T.self)
            }
            guard
                let connection = load("CGSMainConnectionID", as: MainConnectionID.self),
                let create = load("CGSSpaceCreate", as: SpaceCreate.self),
                let setLevel = load("CGSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
                let addWindows = load("CGSAddWindowsToSpaces", as: SpacesWindows.self),
                let removeWindows = load("CGSRemoveWindowsFromSpaces", as: SpacesWindows.self),
                let show = load("CGSShowSpaces", as: Spaces.self),
                let destroy = load("CGSSpaceDestroy", as: SpaceDestroy.self)
            else { return nil }
            return API(connection: connection, create: create, setLevel: setLevel, addWindows: addWindows,
                       removeWindows: removeWindows, show: show, destroy: destroy)
        }()
    }

    private let api: API
    private let space: UInt64
    private var windowNumbers: Set<Int> = []

    init?(level: Int32 = WindowSpace.islandLevel) {
        guard let api = API.shared else { return nil }
        let connection = api.connection()
        let space = api.create(connection, 1, nil)
        guard space != 0 else { return nil }
        _ = api.setLevel(connection, space, level)
        api.show(connection, [NSNumber(value: space)] as CFArray)
        self.api = api
        self.space = space
    }

    /// The window must have been ordered in once so it has a window number.
    func add(_ window: NSWindow) {
        let number = window.windowNumber
        guard number > 0, windowNumbers.insert(number).inserted else { return }
        api.addWindows(api.connection(), [NSNumber(value: number)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    func remove(_ window: NSWindow) {
        let number = window.windowNumber
        guard windowNumbers.remove(number) != nil else { return }
        api.removeWindows(api.connection(), [NSNumber(value: number)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    deinit {
        let connection = api.connection()
        let spaces = [NSNumber(value: space)] as CFArray
        if !windowNumbers.isEmpty {
            api.removeWindows(connection, windowNumbers.map { NSNumber(value: $0) } as CFArray, spaces)
        }
        api.destroy(connection, space)
    }
}
