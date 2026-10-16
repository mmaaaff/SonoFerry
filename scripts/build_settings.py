"""Product metadata and installation identities for builds and tools.

These identities are shared by builds and tools and checked against the runtime.
Previous product identifiers and user data are not used as fallbacks.
"""

PRODUCT_NAME = 'SonoFerry'
APP_VERSION, APP_BUILD = '0.2.0', '55'
RELEASE_LABEL = 'Beta 2'
COMPONENT_VERSION, COMPONENT_BUILD = APP_VERSION, APP_BUILD
APP_BUNDLE_ID = 'local.SonoFerry'
ENGINE_BUNDLE_ID = 'local.SonoFerry.Engine'
ENGINE_BUNDLE_PATH = 'Contents/Helpers/SonoFerry Engine.app'
ENGINE_EXECUTABLE_PATH = ENGINE_BUNDLE_PATH + '/Contents/MacOS/SonoFerryEngine'
CAPTURE_BUNDLE_PATH = 'Contents/Helpers/SonoFerry Audio.app'
CAPTURE_EXECUTABLE_PATH = CAPTURE_BUNDLE_PATH + '/Contents/MacOS/SonoFerryAudio'
DRIVER_NAME = 'SonoFerry.driver'
DRIVER_PATH = '/Library/Audio/Plug-Ins/HAL/' + DRIVER_NAME
ENGINE_HASH_KEY = 'SonoFerryEngineCDHash'
PACKAGE_ID = 'local.SonoFerry.package'
DEPLOYMENT = '15.4'
ARCHITECTURE = 'arm64'
SWIFT_TARGET = ARCHITECTURE + '-apple-macos' + DEPLOYMENT
