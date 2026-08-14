import CoreMediaIO
import Foundation

// Entry point for the Fuzzcam camera system extension.
//
// The extension is deliberately tiny: it publishes one virtual camera device
// with a sink stream (which Fuzzcam.app writes processed frames into) and a
// source stream (which Zoom, Meet, Teams and friends capture from), and relays
// between the two. All image processing happens in the app.

let providerSource = FuzzcamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
