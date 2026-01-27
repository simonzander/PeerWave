#
# Custom plugin loader that excludes Firebase from Windows builds
# This wraps the auto-generated flutter/generated_plugins.cmake
#

# Load the auto-generated plugin list
include(flutter/generated_plugins.cmake.bak)

# Remove Firebase from the plugin list (causes linker errors on Windows, only needed for iOS/Android)
list(REMOVE_ITEM FLUTTER_PLUGIN_LIST firebase_core)

# Continue with normal plugin loading (already handled by the included file, but without firebase_core)
