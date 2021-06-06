//
//  SceneViewController.swift
//  ARPanorama
//
//  Created by Fabio de Albuquerque Dela Antonio on 04/06/2021.
//

import UIKit
import ARKit

final class SceneViewController: UIViewController {

    @IBOutlet private weak var sceneView: ARSCNView!

    private var textureCache: CVMetalTextureCache?
    private var planeNode: SCNNode?

    override var prefersStatusBarHidden: Bool {
        true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }

    init() {
        super.init(nibName: String(describing: type(of: self)), bundle: Bundle(for: type(of: self)))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDisplay()
        configureBackgroundEvent()
        configureScene()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        prepareARConfiguration()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    private func configureDisplay() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func configureBackgroundEvent() {
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    private func configureScene() {
        sceneView.rendersCameraGrain = false
        sceneView.rendersMotionBlur = false

//        guard let scene = SCNScene(named: "Main.scn") else {
//            fatalError("Missing scene")
//        }

        guard let scene = SCNScene(named: "Panorama.scn") else {
            fatalError("Missing scene")
        }

        sceneView.scene = scene
        sceneView.session.delegate = self

        ARKitHelpers.create(textureCache: &textureCache, for: sceneView)
    }

    private func prepareARConfiguration() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = true
        configuration.isAutoFocusEnabled = false
        sceneView.session.run(configuration)
    }

    private func configurePlane(with frame: ARFrame) {
        let planeNode = ARKitHelpers.makePlaneNodeForDistance(0.1, frame: frame)

        planeNode.geometry?.firstMaterial?.transparencyMode = .rgbZero

        planeNode.geometry?.firstMaterial?.shaderModifiers = [
            .surface:
                Shaders.surfaceChromaKey(
                    red: 0.47, green: 0.74, blue: 0.47,
                    sensitivity: 0.105,
                    smoothness: 0.025
                )
        ]

        sceneView.pointOfView?.addChildNode(planeNode)
        self.planeNode = planeNode
    }

    private func updatePlane(with frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let luma = ARKitHelpers.texture(from: pixelBuffer, format: .r8Unorm, planeIndex: 0, textureCache: textureCache)
        let chroma = ARKitHelpers.texture(from: pixelBuffer, format: .rg8Unorm, planeIndex: 1, textureCache: textureCache)

        planeNode?.geometry?.firstMaterial?.transparent.contents = luma
        planeNode?.geometry?.firstMaterial?.diffuse.contents = chroma
    }

    // MARK: - Actions

    @objc private func willResignActive() {
        dismiss(animated: false, completion: nil)
    }
}

extension SceneViewController: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if planeNode == nil {
            configurePlane(with: frame)
        }

        updatePlane(with: frame)
    }
}

struct ARKitHelpers {

    static func planeSizeForDistance(_ distance: Float, frame: ARFrame) -> CGSize {
        let projection = frame.camera.projectionMatrix
        let yScale = projection[1,1]
        let imageResolution = frame.camera.imageResolution
        let width = (2.0 * distance) * tan(atan(1/yScale) * Float(imageResolution.width / imageResolution.height))
        let height = width * Float(imageResolution.height / imageResolution.width)
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    static func makePlane(size: CGSize, distance: Float) -> SCNNode {
        let plane = SCNPlane(width: size.width, height: size.height)
        plane.cornerRadius = 0
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.diffuse.contents = UIColor(red: 0, green: 0, blue: 0, alpha: 1)

        let planeNode = SCNNode(geometry: plane)
        planeNode.position = .init(0, 0, -distance)
        return planeNode
    }

    static func makePlaneNodeForDistance(_ distance: Float, frame: ARFrame) -> SCNNode {
        makePlane(size: planeSizeForDistance(distance, frame: frame), distance: distance)
    }

    @discardableResult
    static func create(textureCache: inout CVMetalTextureCache?, for sceneView: SCNView) -> Bool {
        guard let metalDevice = sceneView.device else {
            return false
        }

        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &textureCache
        )

        return result == kCVReturnSuccess
    }

    static func texture(
        from pixelBuffer: CVPixelBuffer,
        format: MTLPixelFormat,
        planeIndex: Int,
        textureCache: CVMetalTextureCache?
    ) -> MTLTexture? {
        guard let textureCache = textureCache,
            planeIndex >= 0, planeIndex < CVPixelBufferGetPlaneCount(pixelBuffer)
        else {
            return nil
        }

        var texture: MTLTexture?

        let width =  CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        var textureRef : CVMetalTexture?

        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            planeIndex,
            &textureRef
        )

        if result == kCVReturnSuccess, let textureRef = textureRef {
            texture = CVMetalTextureGetTexture(textureRef)
        }

        return texture
    }
}

struct Shaders {

    static let yCrCbToRGB = """
    float BT709_nonLinearNormToLinear(float normV) {
        if (normV < 0.081) {
            normV *= (1.0 / 4.5);
        } else {
            float a = 0.099;
            float gamma = 1.0 / 0.45;
            normV = (normV + a) * (1.0 / (1.0 + a));
            normV = pow(normV, gamma);
        }
        return normV;
    }

    vec4 yCbCrToRGB(float luma, vec2 chroma) {
        float y = luma;
        float u = chroma.r - 0.5;
        float v = chroma.g - 0.5;

        const float yScale = 255.0 / (235.0 - 16.0); //(BT709_YMax-BT709_YMin)
        const float uvScale = 255.0 / (240.0 - 16.0); //(BT709_UVMax-BT709_UVMin)

        y = y - 16.0/255.0;
        float r = y*yScale + v*uvScale*1.5748;
        float g = y*yScale - u*uvScale*1.8556*0.101 - v*uvScale*1.5748*0.2973;
        float b = y*yScale + u*uvScale*1.8556;

        r = clamp(r, 0.0, 1.0);
        g = clamp(g, 0.0, 1.0);
        b = clamp(b, 0.0, 1.0);

        r = BT709_nonLinearNormToLinear(r);
        g = BT709_nonLinearNormToLinear(g);
        b = BT709_nonLinearNormToLinear(b);
        return vec4(r, g, b, 1.0);
    }

    """

    static let rgbToYCrCb = """
    vec3 rgbToYCrCb(vec3 c) {
        float y = 0.2989 * c.r + 0.5866 * c.g + 0.1145 * c.b;
        float cr = 0.7132 * (c.r - y);
        float cb = 0.5647 * (c.b - y);
        return vec3(y, cr, cb);
    }

    """

    static let thresholdChromaKey = """
    \(rgbToYCrCb)

    float thresholdChromaKey(vec3 c, vec3 maskColor, float t) {
        vec3 convertedMask = rgbToYCrCb(maskColor);
        float maskCr = convertedMask.g;
        float maskCb = convertedMask.b;

        vec3 convertedColor = rgbToYCrCb(c);
        float Cr = convertedColor.g;
        float Cb = convertedColor.b;

        if (distance(vec2(Cr, Cb), vec2(maskCr, maskCb)) < t) {
            return 1.0;
        } else {
            return 0.0;
        }
    }

    """

    static let smoothChromaKey = """
    \(rgbToYCrCb)

    float smoothChromaKey(vec3 c, vec3 maskColor, float sensitivity, float smoothness) {
        vec3 convertedMask = rgbToYCrCb(maskColor);
        float maskCr = convertedMask.g;
        float maskCb = convertedMask.b;

        vec3 convertedColor = rgbToYCrCb(c);
        float Cr = convertedColor.g;
        float Cb = convertedColor.b;

        return 1.0 - smoothstep(sensitivity, sensitivity + smoothness, distance(vec2(Cr, Cb), vec2(maskCr, maskCb)));
    }

    """

    static func surfaceChromaKey(red: Float, green: Float, blue: Float, threshold: Float) -> String {
        """
        \(yCrCbToRGB)
        \(thresholdChromaKey)

        #pragma body

        float luma = texture2D(u_transparentTexture, _surface.diffuseTexcoord).r;
        vec2 chroma = texture2D(u_diffuseTexture, _surface.diffuseTexcoord).rg;

        vec4 textureColor = yCbCrToRGB(luma, chroma);
        _surface.diffuse = textureColor;

        float blendValue = thresholdChromaKey(textureColor.rgb, vec3(\(red), \(green), \(blue)), \(threshold));
        _surface.transparent = vec4(blendValue, blendValue, blendValue, 1.0);
        """
    }

    static func surfaceChromaKey(red: Float, green: Float, blue: Float, sensitivity: Float, smoothness: Float) -> String {
        """
        \(yCrCbToRGB)
        \(smoothChromaKey)

        #pragma body

        float luma = texture2D(u_transparentTexture, _surface.diffuseTexcoord).r;
        vec2 chroma = texture2D(u_diffuseTexture, _surface.diffuseTexcoord).rg;

        vec4 textureColor = yCbCrToRGB(luma, chroma);
        _surface.diffuse = textureColor;

        float blendValue = smoothChromaKey(textureColor.rgb, vec3(\(red), \(green), \(blue)), \(sensitivity), \(smoothness));
        _surface.transparent = vec4(blendValue, blendValue, blendValue, 1.0);
        """
    }
}
