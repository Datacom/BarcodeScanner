import UIKit
import AVFoundation

// MARK: - Delegates

/// Delegate to handle the captured code.
public protocol BarcodeScannerCodeDelegate: class {
  func barcodeScanner(_ controller: BarcodeScannerController, didCaptureCode code: String, type: String)
}

/// Delegate to report errors.
public protocol BarcodeScannerErrorDelegate: class {
  func barcodeScanner(_ controller: BarcodeScannerController, didReceiveError error: Error)
}

/// Delegate to dismiss barcode scanner when the close button has been pressed.
public protocol BarcodeScannerDismissalDelegate: class {
  func barcodeScannerDidDismiss(_ controller: BarcodeScannerController)
}

// MARK: - Controller

/**
 Barcode scanner controller with 4 sates:
 - Scanning mode
 - Processing animation
 - Unauthorized mode
 - Not found error message
 */
open class BarcodeScannerController: UIViewController {
  
  /// Video capture device.
  lazy var captureDevice: AVCaptureDevice = AVCaptureDevice.default(for: AVMediaType.video)!
  
  /// Capture session.
  lazy var captureSession: AVCaptureSession = AVCaptureSession()
  
  /// Video preview layer.
  var videoPreviewLayer: AVCaptureVideoPreviewLayer?
  
  /// Button to change torch mode.
  public lazy var flashButton: UIButton = { [unowned self] in
    let button = UIButton(type: .custom)
    button.addTarget(self, action: #selector(flashButtonDidPress), for: .touchUpInside)
    return button
    }()
  
  /// Button that opens settings to allow camera usage.
  lazy var settingsButton: UIButton = { [unowned self] in
    let button = UIButton(type: .system)
    let title = NSAttributedString(string: SettingsButton.text,
                                   attributes: [
                                    NSAttributedStringKey.font : SettingsButton.font,
                                    NSAttributedStringKey.foregroundColor : SettingsButton.color,
                                    ])
    
    button.setAttributedTitle(title, for: UIControlState())
    button.sizeToFit()
    button.addTarget(self, action: #selector(settingsButtonDidPress), for: .touchUpInside)
    
    return button
    }()
  
  /// The current torch mode on the capture device.
  var torchMode: TorchMode = .off {
    didSet {
      guard captureDevice.hasFlash else { return }
      
      do {
        try captureDevice.lockForConfiguration()
        captureDevice.torchMode = torchMode.captureTorchMode
        captureDevice.unlockForConfiguration()
      } catch {}
      
      flashButton.setImage(torchMode.image, for: UIControlState())
    }
  }
  
  /// The current controller's status mode.
  var status: State = .scanning {
    didSet {
      
      let delayReset = oldValue == .processing
      
      if !delayReset {
        resetState()
      } else {
        let delayTime = DispatchTime.now() + Double(Int64(0.5 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
        DispatchQueue.main.asyncAfter(deadline: delayTime) {
          self.resetState()
        }
      }
    }
  }

  
  /// When the flag is set to `true` controller returns a captured code
  /// and waits for the next reset action.
  public var isOneTimeSearch = true
  
  /// Delegate to handle the captured code.
  public weak var codeDelegate: BarcodeScannerCodeDelegate?
  
  /// Delegate to report errors.
  public weak var errorDelegate: BarcodeScannerErrorDelegate?
  
  /// Delegate to dismiss barcode scanner when the close button has been pressed.
  public weak var dismissalDelegate: BarcodeScannerDismissalDelegate?
  
  /// Flag to lock session from capturing.
  var locked = false
  
  // MARK: - Initialization
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  // MARK: - View lifecycle
  
  open override func viewDidLoad() {
    super.viewDidLoad()
    
    videoPreviewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
    videoPreviewLayer?.videoGravity = AVLayerVideoGravity.resizeAspectFill
    
    view.backgroundColor = UIColor.black
    
    guard let videoPreviewLayer = videoPreviewLayer else {
      return
    }
    
    view.layer.addSublayer(videoPreviewLayer)
    
    [settingsButton, flashButton].forEach {
        view.addSubview($0)
        view.bringSubview(toFront: $0)
    }
    
    torchMode = .off
    
    setupCamera()
    
    NotificationCenter.default.addObserver(
      self, selector: #selector(appWillEnterForeground),
      name: NSNotification.Name.UIApplicationWillEnterForeground,
      object: nil)
  }
  
  open override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    self.setupFrame()
  }
  
  /**
   `UIApplicationWillEnterForegroundNotification` action.
   */
  @objc func appWillEnterForeground() {
    torchMode = .off
  }
  
  // MARK: - Configuration
  
  /**
   Sets up camera and checks for camera permissions.
   */
  func setupCamera() {
    let authorizationStatus = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
    
    if authorizationStatus == .authorized {
      setupSession()
      status = .scanning
    } else if authorizationStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: AVMediaType.video,
                                    completionHandler: { (granted: Bool) -> Void in
                                      DispatchQueue.main.async {
                                        if granted {
                                          self.setupSession()
                                        }
                                        
                                        self.status = granted ? .scanning : .unauthorized
                                      }
      })
    } else {
      status = .unauthorized
    }
  }
  
  /**
   Sets up capture input, output and session.
   */
  func setupSession() {
    do {
      let input = try AVCaptureDeviceInput(device: captureDevice)
      captureSession.addInput(input)
    } catch {
      errorDelegate?.barcodeScanner(self, didReceiveError: error)
    }
    
    let output = AVCaptureMetadataOutput()
    captureSession.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
    output.metadataObjectTypes = metadata
    videoPreviewLayer?.session = captureSession
    
    view.setNeedsLayout()
  }
  
  // MARK: - Reset
  
  /**
   Resets the controller to the scanning mode.
   
   - Parameter animated: Flag to show scanner with or without animation.
   */
  public func reset(animated: Bool = true) {
    status = .scanning
  }
  
  /**
   Resets the current state.
   */
  func resetState() {
    let alpha: CGFloat = status == .scanning ? 1 : 0
    
    torchMode = .off
    locked = status == .processing && isOneTimeSearch
    
    status == .scanning
      ? captureSession.startRunning()
      : captureSession.stopRunning()
    
    flashButton.alpha = alpha
    
    let authorizationStatus = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)

    settingsButton.isHidden = authorizationStatus == .authorized || authorizationStatus == .notDetermined
  }
  
  // MARK: - Layout
  func setupFrame() {
    flashButton.frame = CGRect(x: view.frame.width - 50, y: 73, width: 37, height: 37)
    
    if let videoPreviewLayer = videoPreviewLayer {
      videoPreviewLayer.frame = view.layer.bounds
      if let connection = videoPreviewLayer.connection, connection.isVideoOrientationSupported {
        switch (UIApplication.shared.statusBarOrientation) {
        case .portrait: connection.videoOrientation = .portrait
        case .landscapeRight: connection.videoOrientation = .landscapeRight
        case .landscapeLeft: connection.videoOrientation = .landscapeLeft
        case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
        default: connection.videoOrientation = .portrait
        }
      }
    }
    
    center(subview: settingsButton, inSize: CGSize(width: 150, height: 50))
  }
  
  /**
   Sets a new size and center aligns subview's position.
   
   - Parameter subview: The subview.
   - Parameter size: A new size.
   */
  func center(subview: UIView, inSize size: CGSize) {
    subview.frame = CGRect(
      x: (view.frame.width - size.width) / 2,
      y: (view.frame.height - size.height) / 2,
      width: size.width,
      height: size.height)
  }
  
  // MARK: - Animations
  
  /**
   Simulates flash animation.
   
   - Parameter processing: Flag to set the current state to `.Processing`.
   */
  func animateFlash(whenProcessing: Bool = false) {
    let flashView = UIView(frame: view.bounds)
    flashView.backgroundColor = UIColor.white
    flashView.alpha = 1
    
    view.addSubview(flashView)
    view.bringSubview(toFront: flashView)
    
    UIView.animate(withDuration: 0.2,
                   animations: {
                    flashView.alpha = 0.0
    },
                   completion: { [weak self] _ in
                    flashView.removeFromSuperview()
                    
                    if whenProcessing {
                      self?.status = .processing
                    }
    })
  }
  
  // MARK: - Actions
  
  /**
   Opens setting to allow camera usage.
   */
  @objc func settingsButtonDidPress() {
    DispatchQueue.main.async {
      if let settingsURL = URL(string: UIApplicationOpenSettingsURLString) {
        UIApplication.shared.openURL(settingsURL)
      }
    }
  }
  
  /**
   Sets the next torch mode.
   */
  @objc func flashButtonDidPress() {
    torchMode = torchMode.next
  }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension BarcodeScannerController: AVCaptureMetadataOutputObjectsDelegate {
  
  public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    guard !locked else { return }
    guard !metadataObjects.isEmpty else { return }
    
    guard
      let metadataObj = metadataObjects[0] as? AVMetadataMachineReadableCodeObject,
      var code = metadataObj.stringValue,
      metadata.contains(metadataObj.type)
      else { return }
    
    if isOneTimeSearch {
      locked = true
    }
    
    var rawType = metadataObj.type.rawValue
    
    // UPC-A is an EAN-13 barcode with a zero prefix.
    // See: https://stackoverflow.com/questions/22767584/ios7-barcode-scanner-api-adds-a-zero-to-upca-barcode-format
    if metadataObj.type == AVMetadataObject.ObjectType.ean13 && code.hasPrefix("0") {
      code = String(code.dropFirst())
      rawType = AVMetadataObject.ObjectType.upca.rawValue
    }
    
    codeDelegate?.barcodeScanner(self, didCaptureCode: code, type: rawType)
    animateFlash(whenProcessing: isOneTimeSearch)
  }
}
