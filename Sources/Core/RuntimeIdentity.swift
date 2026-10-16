/// SonoFerry installation and storage identities shared by the App and engine.
/// Keep the build, installer and runtime paths aligned; old product data is not migrated.
public enum RuntimeIdentity {
    public static let preferencesDomain = "local.SonoFerry"
    public static let cacheDirectory = "SonoFerry"
    public static let engineBundlePath = "Contents/Helpers/SonoFerry Engine.app"
    public static let engineExecutablePath = engineBundlePath + "/Contents/MacOS/SonoFerryEngine"
    public static let captureBundlePath = "Contents/Helpers/SonoFerry Audio.app"
    public static let captureExecutablePath = captureBundlePath + "/Contents/MacOS/SonoFerryAudio"
    public static let driverPath = "/Library/Audio/Plug-Ins/HAL/SonoFerry.driver"
    public static let engineHashKey = "SonoFerryEngineCDHash"
}
