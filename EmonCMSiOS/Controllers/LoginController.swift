//
//  LoginController.swift
//  EmonCMSiOS
//
//  Created by Matt Galloway on 13/09/2016.
//  Copyright © 2016 Matt Galloway. All rights reserved.
//

import Foundation
import Locksmith

protocol LoginControllerDelegate: class {

}

class LoginController {

  weak var delegate: LoginControllerDelegate?

  enum LoginControllerError: Error {
    case Generic
    case KeychainFailed
  }

  private(set) var account: Account?

  private enum UserDefaultKeys: String {
    case accountURL
    case accountUUID
  }

  init() {
    self.loadAccount()
  }

  private func loadAccount() {
    guard
    let accountURL = UserDefaults.standard.string(forKey: UserDefaultKeys.accountURL.rawValue),
    let accountUUIDString = UserDefaults.standard.string(forKey: UserDefaultKeys.accountUUID.rawValue),
    let accountUUID = UUID(uuidString: accountUUIDString)
    else { return }

    guard let data = Locksmith.loadDataForUserAccount(userAccount: accountUUIDString),
      let apikey = data["apikey"] as? String
      else {
        return
    }

    let account = Account(uuid: accountUUID, url: accountURL, apikey: apikey)
    self.account = account
  }

  func login(withAccount account: Account) throws {
    do {
      let data = ["apikey": account.apikey]
      do {
        try Locksmith.saveData(data: data, forUserAccount: account.uuid.uuidString)
      } catch LocksmithError.duplicate {
        // We already have it, let's try updating it
        try Locksmith.updateData(data: data, forUserAccount: account.uuid.uuidString)
      }
      UserDefaults.standard.set(account.url, forKey: UserDefaultKeys.accountURL.rawValue)
      UserDefaults.standard.set(account.uuid.uuidString, forKey: UserDefaultKeys.accountUUID.rawValue)
      self.account = account
    } catch {
      throw LoginControllerError.KeychainFailed
    }
  }

  func logout() throws {
    guard let accountURL = UserDefaults.standard.string(forKey: UserDefaultKeys.accountURL.rawValue) else {
      throw LoginControllerError.Generic
    }
    do {
      try Locksmith.deleteDataForUserAccount(userAccount: accountURL)
      UserDefaults.standard.removeObject(forKey: UserDefaultKeys.accountURL.rawValue)
      self.account = nil
    } catch {
      throw LoginControllerError.KeychainFailed
    }
  }

}
