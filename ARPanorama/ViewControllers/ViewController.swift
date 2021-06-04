//
//  ViewController.swift
//  ARPanorama
//
//  Created by Fabio de Albuquerque Dela Antonio on 04/06/2021.
//

import UIKit

final class ViewController: UIViewController {

    init() {
        super.init(nibName: String(describing: type(of: self)), bundle: Bundle(for: type(of: self)))
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    @IBAction func startAction(_ sender: Any) {
        let viewController = SceneViewController()
        viewController.modalPresentationStyle = .overFullScreen
        present(viewController, animated: true, completion: nil)
    }
}
