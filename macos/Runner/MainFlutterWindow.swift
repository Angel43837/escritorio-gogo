import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Ventana de tamaño moderado y centrada al abrir — nada de pantalla
    // completa con espacio vacío alrededor; el usuario la puede hacer más
    // chica o más grande jalando sus bordes normales.
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    let size = NSSize(width: 1000, height: 700)
    let origin = NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)
    self.setFrame(NSRect(origin: origin, size: size), display: true)
    self.minSize = NSSize(width: 420, height: 500)
    // El restaurante debe ver siempre esta ventana encima de cualquier otra
    // app — para ver algo detrás hay que minimizar/cerrar esta.
    self.level = .floating

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
