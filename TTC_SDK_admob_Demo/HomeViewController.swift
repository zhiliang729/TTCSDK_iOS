//
//  HomeViewController.swift
//  TTC_SDK_admob_Demo
//
//  Created by chenchao on 2019/1/2.
//  Copyright © 2019 tataufo. All rights reserved.
//

import UIKit
import TTCSDK

let userIDP = "userID: "
let addressP = "address: "

class HomeViewController: UIViewController {
    
    @IBOutlet weak var userLabel: UILabel!
    @IBOutlet weak var addressLabel: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view.
        
        if let uid = userID, !uid.isEmpty {
            let user = TTCUserInfo(userId: uid)
            TTCSDK.login(userInfo: user, result: { (success, error, user) in
                if success, let u = user {
                    self.userLabel.text = userIDP + u.userId.description
                    self.addressLabel.text = addressP + (u.address ?? "null")
                    
                    let rightItem = UIBarButtonItem.init(title: "logout", style: UIBarButtonItem.Style.done, target: self, action: #selector(self.rightClick))
                    self.navigationItem.rightBarButtonItem = rightItem
                }
            })
            
        } else {
            
            let rightItem = UIBarButtonItem.init(title: "login", style: UIBarButtonItem.Style.done, target: self, action: #selector(rightClick))
            self.navigationItem.rightBarButtonItem = rightItem
        }
    }
    
    @objc func rightClick() {
        
        if let uid = userID, !uid.isEmpty {
            
            userID = ""
            self.userLabel.text = userIDP
            self.addressLabel.text = addressP
            
            TTCSDK.logout()
            let rightItem = UIBarButtonItem.init(title: "login", style: UIBarButtonItem.Style.done, target: self, action: #selector(self.rightClick))
            self.navigationItem.rightBarButtonItem = rightItem
            
        } else {
            
            let user = TTCUserInfo(userId: Int(Date().timeIntervalSince1970).description)
            TTCSDK.login(userInfo: user, result: { (success, error, user) in
                if success, let u = user {
                    self.userID = u.userId
                    self.userLabel.text = userIDP + u.userId.description
                    self.addressLabel.text = addressP + (u.address ?? "null")
                    
                    let rightItem = UIBarButtonItem.init(title: "logout", style: UIBarButtonItem.Style.done, target: self, action: #selector(self.rightClick))
                    self.navigationItem.rightBarButtonItem = rightItem
                }
            })
        }
    }
    
    // MARK: -- App当前语言
    var userID: String? {
        set {
            UserDefaults.standard.set(newValue, forKey: "getUserID")
            UserDefaults.standard.synchronize()
        }
        
        get {
            return UserDefaults.standard.string(forKey: "getUserID")
        }
    }
}
