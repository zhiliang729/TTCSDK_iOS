//
//  ActionManager.swift
//  TTC_SDK
//
//  Created by Zhang Yufei on 2018/7/9  下午12:15.
//  Copyright © 2018年 tataufo. All rights reserved.
//

import Foundation
import RealmSwift
import BigInt
import JSONRPCKit
import APIKit
import TTC_SDK_NET

class TTCActionInfo: Object {
    
    /// actionType > 100
    @objc dynamic var actionType: Int32 = 0
    /// Transaction number
    @objc dynamic var actionHash: String = String()
    /// nonce
    @objc dynamic var nonce: Int64 = -1
    /// from user id
    @objc dynamic var fromUserID: String = String()
    /// Ancillary information
    @objc dynamic var extra: String = String()
    /// Have you uploaded the behavior to the server? 0 = no  1 = yes
    @objc dynamic var isUpload: Int = 0
    /// Have you checked? 0 = no  1 = yes, Waiting for a block  2 = yes, Block failure  3 = yes, Block success
    @objc dynamic var isCheck: Int = 0
    /// time
    @objc dynamic var timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    /// Database primary key
    override class func primaryKey() -> String? { return "timestamp" }
    
    func hashData() -> Data {
        var hashString = "actionType=\(self.actionType)&extra=\(self.extra)&fromUserId=\(self.fromUserID)&timestamp=\(self.timestamp)".md5()
        hashString = "ufo:1:oplog:md5:\(hashString):\(TTCManager.shared.appId.description)"
        return hashString.data(using: .utf8) ?? Data()
    }
    
    func transitionProto() -> TTCNETActionInfo {
        
        let pbActionInfo = TTCNETActionInfo()
        pbActionInfo.actionType = self.actionType
        pbActionInfo.fromUserID = self.fromUserID
        pbActionInfo.actionHash = self.actionHash
        pbActionInfo.timestamp = self.timestamp
        pbActionInfo.extra = self.extra
        
        return pbActionInfo
    }
    
    /// Ignored attributes are not stored in the database
    override static func ignoredProperties() -> [String] {
        return ["description"]
    }
    
    override var description: String {
        get {
            return "actionType=\(self.actionType)\nextra=\(self.extra)\nfromUserId=\(self.fromUserID)\ntimestamp=\(self.timestamp)\nactionHash=\(self.actionHash)"
        }
    }
}

class TTCActionManager {
    
    let realmQueue = DispatchQueue(label: "realmQueue")
    let cfg: Realm.Configuration
    var realm: Realm {
        get {
            return try! Realm(configuration: cfg)
        }
    }
    var timer: Timer?
    
    /// gas limit
    var gasLimit: BigInt = BigInt(210000)
    /// gas price
    var gasPrice: BigInt = BigInt("500000000000") // 500 gwei
    
    /// nonce
    var nonce: BigInt = BigInt(-1)
    
    /// chainID
    var chainID: BigInt?
    
    /// Maximum upload behavior
    let uploadCountLimit = 1
    /// is uploading behavior?
    var isUploadAction: Bool = false
    /// is transaction?
    var isTransaction: Bool = false
    /// error count for 'requestPrivateKeyAndAddress'
    var transactionErrorCount: Int {
        didSet {
            if transactionErrorCount > 5 {
                transactionErrorCount = 0
                TTCManager.shared.requestPrivateKeyAndAddress { (_, _) -> Void in }
            }
        }
    }
    
    var timeInterval: TimeInterval = 30
    
    static let shared = TTCActionManager()
    
    init() {
        
        var realmPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        realmPath += "/action.realm"
        var bid = Bundle.main.bundleIdentifier ?? ""
        bid = bid.md5()
        var ttc = "ttc-" + bid
        ttc = ttc.md5()
        var key = ttc + bid
        let i = key.index(key.startIndex, offsetBy: 64)
        key = String(key.prefix(upTo: i))
        let data = key.data(using: .utf8) ?? Data()
        cfg = Realm.Configuration.init(fileURL: URL(string: realmPath), encryptionKey: data, readOnly: false, schemaVersion: 2, migrationBlock: { migration, oldSchemaVersion in
            if oldSchemaVersion < 2{
                
            }
        }, deleteRealmIfMigrationNeeded: false, shouldCompactOnLaunch: nil, objectTypes: nil)
        
        transactionErrorCount = 0
    }
    
    func runScheduledTimer() {
        self.timer = Timer.scheduledTimer(timeInterval: timeInterval, target: self, selector: #selector(checkTransaction), userInfo: nil, repeats: true)
    }
    
    
    func setDefaultManager() {
        
        self.gasLimit = BigInt(210000)
        self.gasPrice = BigInt("500000000000") // 500 gwei
        self.nonce = BigInt(-1)
        
        self.transactionErrorCount = 0
        
        self.timer?.invalidate()
        self.timer = nil
        self.timeInterval = 30
        
        runScheduledTimer()
        
    }
    
    /// Behavior write to database
    func insertAction(actionInfo: TTCActionInfo) {
        realmQueue.async {
            let realm = self.realm
            try? realm.write {
                realm.add(actionInfo, update: true)
            }
            //            TTCPrint(actionInfo)
            self.actionWriteBlockChain(actionInfo: actionInfo)
        }
    }
    
    /// remove behavior from database
    func deleteAction() {
        
        realmQueue.async {
            
            guard let userinfo = TTCManager.shared.userInfo else { return }
            
            let realm = self.realm
            let actionInfos = realm.objects(TTCActionInfo.self).filter("fromUserID = '\(userinfo.userId)' AND actionHash != '' AND isUpload = 1 AND isCheck = 3")
            try? realm.write {
                realm.delete(actionInfos)
            }
        }
    }
    
    /// query and upload
    func queriesActionAndUpload() {
        realmQueue.async {
            if self.isUploadAction { return }
            guard let userinfo = TTCManager.shared.userInfo else { return }
            
            let results = self.realm.objects(TTCActionInfo.self).filter("fromUserID = '\(userinfo.userId)' AND actionHash != '' AND isUpload = 0")
            if results.count >= self.uploadCountLimit {
                self.isUploadAction = true
                
                var ecoActions: [TTCNETActionInfo] = []
                for action in results {
                    ecoActions.append(action.transitionProto())
                }
                
                TTCPrint("start upload behavior....")
                self.uploadAction(ecoActions: ecoActions)
            }
        }
    }
    
    /// Update upload status to uploaded
    func updateAction(actionInfos: [TTCNETActionInfo]) {
        realmQueue.async {
            let realm = self.realm
            for action in actionInfos {
                guard let act = realm.objects(TTCActionInfo.self).filter("timestamp = \(action.timestamp)").first else { return }
                try? realm.write {
                    act.isUpload = 1
                }
            }
        }
    }
    
    /// query and transaction
    func queriesActionAndTransaction() {
        realmQueue.async {
            if self.isTransaction { return }
            guard let userinfo = TTCManager.shared.userInfo else { return }
            
            guard let actionInfo = self.realm.objects(TTCActionInfo.self).filter("fromUserID = '\(userinfo.userId)' AND actionHash = ''").first else { return }
            self.actionWriteBlockChain(actionInfo: actionInfo)
        }
    }
    
    /// upload block chain
    func actionWriteBlockChain(actionInfo: TTCActionInfo) {
        
        if self.isTransaction {
            TTCPrint("Trading. . .")
            return
        }
        
        /// get chainid
        guard let chainId = self.chainID else {
            getChainID()
            return
        }
        
        /// fetch nonce
        if self.nonce == BigInt(-1) {
            getTransactionCount()
            return
        }
        
        /// start transaction
        self.isTransaction = true
        
        let nonce: BigInt
        let data: Data
        let timestamp: Int64
        let gasLimit: BigInt
        let gasPrice: BigInt
        
        nonce = self.nonce
        data = actionInfo.hashData()
        timestamp = actionInfo.timestamp
        gasLimit = self.gasLimit
        gasPrice = self.gasPrice
        
        if actionInfo.fromUserID != TTCManager.shared.userInfo?.userId {
            self.isTransaction = false
            return
        }
        
        guard let userinfo = TTCManager.shared.userInfo else {
            self.isTransaction = false
            return
        }
        
        let trans = Transaction(
            from: TTCManager.shared.actionAddress ?? "",
            to: userinfo.address ?? "",
            gasLimit: gasLimit,
            gasPrice: gasPrice,
            value: EtherNumberFormatter.full.number(from: String(Int(0)), units: EthereumUnit.wei) ?? BigInt(0),
            nonce: nonce,
            data: data,
            chainID: chainId)
        
        TTCRPCManager.sendTransaction(transaction: trans) { (result) in
            switch result {
            case .success(let hex):
                TTCPrint("Transaction success -> hash: \(hex)")
                self.realmQueue.async {
                    
                    /// update database
                    let realm = self.realm
                    let action = realm.objects(TTCActionInfo.self).filter("timestamp = \(timestamp)").first
                    try? realm.write {
                        action?.actionHash = hex
                        action?.nonce = Int64(nonce.description) ?? 0
                        action?.isUpload = 0 // 有可能被上传服务器后设为1了
                    }
                }
                
                //                TTCRPCManager.getTransaction(hash: hex) { (result) in
                //                    switch result {
                //                    case .success(let transaction):
                //                        TTCPrint("Transaction hash: \(hex), info: \(transaction)")
                //                    case .failure(_): break
                //                    }
                //                }
                
                self.nonce += 1
                TTCPrint("current nonce: \(self.nonce)")
                self.isTransaction = false
                /// Inquire whether there is no transaction, initiate a transaction
                self.queriesActionAndTransaction()
                self.queriesActionAndUpload()
            case .failure(let error):
                
                TTCPrint("Transaction failed: \(error)")
                /// end transation
                self.isTransaction = false
                self.transactionErrorCount += 1
                
                self.doError(error: error)
            }
        }
    }
    
    /// Upload user behavior to the server
    func uploadAction(ecoActions: [TTCNETActionInfo]) {
        
        TTCPrint("behavior count :\(ecoActions.count)")
        
        if ecoActions.first?.fromUserID != TTCManager.shared.userInfo?.userId {
            self.isUploadAction = false
            return
        }
        
        TTCNetworkManager.uploadAction(actionInfoList: ecoActions, result: { (success, error) in
            
            if success {
                TTCPrint("Upload behavior succeeded")
                self.updateAction(actionInfos: ecoActions)
                self.queriesActionAndUpload()
            } else {
                TTCPrint("Upload behavior failed: \(String(describing: error?.errorDescription))")
            }
            
            self.isUploadAction = false
        })
    }
    
    // query transaction count
    func getTransactionCount() {
        
        guard let address = TTCManager.shared.actionAddress, !address.isEmpty else {
            return
        }
        
        let userid = TTCManager.shared.userInfo?.userId
        
        TTCRPCManager.getTransactionPendingCount(address: address, completion: { (result) in
            switch result {
            case .success(let nonce):
                TTCPrint("fetch nonce success, nonce: \(nonce.description)")
                
                //                guard let userinfo = TTCManager.shared.userInfo else { return }
                
                //                if let action = self.realm.objects(TTCActionInfo.self).filter("fromUserID = '\(userinfo.userId)' AND nonce > -1").sorted(byKeyPath: "nonce").last {
                //                    TTCPrint("Database nonce: \(action.nonce)")
                //                    self.nonce = BigInt(action.nonce) + 1
                //                }
                
                self.nonce = nonce
                
                if userid != TTCManager.shared.userInfo?.userId{
                    self.nonce = BigInt(-1)
                }
                
                TTCPrint("Used nonce: \(self.nonce.description)")
                
                self.queriesActionAndTransaction()
                self.deleteAction()
                
            case .failure(let error):
                TTCPrint("Get nonce failed: \(error)")
            }
        })
    }
    
    // version
    func getChainID() {
        TTCRPCManager.fetchVersion { (result) in
            switch result {
            case .success(let version):
                TTCPrint("Get chainid success: \(version)")
                self.chainID = BigInt(version)
            case .failure(let error):
                TTCPrint("Get chainid failed: \(error)")
            }
        }
    }
    
    // query transaction and receipt by hash
    func transactionBill(hash: String, completion: @escaping ([String: AnyObject]?, Bool?, SessionTaskError?) -> Void) {
        
        TTCRPCManager.getTransaction(hash: hash) { (result) in
            switch result {
            case .success(let transaction):
                TTCPrint("Transaction hash: \(hash), info: \(transaction)")
                
                let blockNumberStr = transaction["blockNumber"] as? String ?? ""
                let blockNumber = BigInt(blockNumberStr.drop0x, radix: 16) ?? BigInt(0)
                if blockNumber > BigInt(0) {
                    
                    TTCRPCManager.getTransactionReceipt(hash: hash, completion: { (result) in
                        switch result {
                        case .success(let receipt):
                            TTCPrint("Get receipt succedd, hash:\(hash), receipt.status: \(receipt.status)")
                            completion(transaction, receipt.status, nil)
                        case .failure(let error):
                            TTCPrint("Get receipt failed: \(error)")
                            completion(transaction, nil, error)
                        }
                    })
                } else {
                    TTCPrint("Transaction hash: \(hash), the timer has passed, no blockNumber")
                    completion(transaction, nil, nil)
                }
            case .failure(let error):
                TTCPrint("Get transaction failed, hash:\(hash), failed: \(error)")
                completion(nil, nil, error)
            }
        }
    }
    
    @objc func checkAndupload() {
        checkTransaction()
        queriesActionAndUpload()
    }
    
    @objc func checkTransaction() {
        
        if !TTCManager.shared.isRegister { return }
        guard let userinfo = TTCManager.shared.userInfo else { return }
        
        let userid = TTCManager.shared.userInfo?.userId
        
        if let actionInfo = self.realm.objects(TTCActionInfo.self).filter("fromUserID = '\(userinfo.userId)' AND actionHash != '' AND isCheck < 3").sorted(byKeyPath: "nonce").first {
            
            if userid != userinfo.userId { return }
            
            let hash = actionInfo.actionHash
            
            TTCRPCManager.getTransaction(hash: hash) { (result) in
                switch result {
                case .success(let transaction):
                    TTCPrint("Transaction hash: \(hash), info: \(transaction)")
                    
                    if userid != userinfo.userId { return }
                    
                    let blockNumberStr = transaction["blockNumber"] as? String ?? ""
                    let blockNumber = BigInt(blockNumberStr.drop0x, radix: 16) ?? BigInt(0)
                    
                    if blockNumber > BigInt(0) {
                        
                        /// update database
                        try? self.realm.write {
                            actionInfo.isCheck = 3 // Check successful
                        }
                        
                        TTCPrint("Transaction hash: \(hash), blockNumber = \(blockNumber)")
                        
                        /// Continue to check
                        self.checkTransaction()
                        
                    } else {
                        
                        /// wait block
                        try? self.realm.write {
                            actionInfo.isCheck = 1 // Not yet successful
                        }
                    
                        
                        TTCPrint("Transaction hash: \(hash), no blockNumber")
                    }
                    
                case .failure(let error):
                    
                    TTCPrint("Get transaction failed, hash:\(hash), failed: \(error)")
                    
                    switch error {
                    case .responseError(let e):
                        
                        guard let RPCError: JSONRPCError = e as? JSONRPCError else {
                            return
                        }
                        
                        switch RPCError {
                            
                        case .resultObjectParseError(let castError):
                            TTCPrint("\(castError)")
                            
                            guard let cast = castError as? CastError<[String: AnyObject]> else {
                                return
                            }
                            
                            TTCPrint("\(cast.actualValue)")
                            
                            if cast.actualValue is NSNull  {
                                /// 一般情况是nonce过大，为了追求实时性，重新上传
                                /// The general situation is that the nonce is too large, in order to pursue real-time, re-upload
                                TTCPrint("is null ------- \(actionInfo.actionHash)")
                                try? self.realm.write {
                                    actionInfo.actionHash = ""  // Hash restore
                                    actionInfo.isCheck = 2      // Block failure
                                    actionInfo.nonce = 0
                                    actionInfo.isUpload = 0     // may be 1
                                }
                                
                            }
                            
                            /// Continue to check
                            self.checkTransaction()
                            /// re-upload
                            self.getTransactionCount()
                            
                        default:
                            break
                        }
                    default:
                        break
                    }
                }
            }
        }
    }
    
    
    /// MARK: - json rpc error
    func dealwithRPCError(error: JSONRPCError) {
        switch error {
        case .responseError(code: _, message: let message, data: _):
            // nonce, Have problems re-query "replacement transaction underpriced"？？？
            if message == "nonce too low" {
                self.getTransactionCount()
            }
        default:
            break
        }
    }
    
    /// return SessionTaskError and jsonrpc
    func doError(error: SessionTaskError) {
        switch error {
        case .responseError(let e):
            
            guard let RPCError: JSONRPCError = e as? JSONRPCError else {
                return
            }
            
            self.dealwithRPCError(error: RPCError)
            
        default:
            break
        }
    }
    
}
