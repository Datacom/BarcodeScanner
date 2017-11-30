import UIKit
import BarcodeScanner

class ViewController: UIViewController {
  
  @IBOutlet weak var scannerView: BarcodeScannerView!
  
  override func viewDidLoad() {
    super.viewDidLoad()
    scannerView.codeDelegate = self
    scannerView.errorDelegate = self
  }
}

extension ViewController: BarcodeScannerCodeDelegate {
  
  func barcodeScanner(_ view: BarcodeScannerView, didCaptureCode code: String, type: String) {
    print("Barcode Data: \(code)")
    print("Symbology Type: \(type)")
    view.reset()
  }
}

extension ViewController: BarcodeScannerErrorDelegate {
  
  func barcodeScanner(_ controller: BarcodeScannerView, didReceiveError error: Error) {
    print(error)
  }
}
