//
//  MyElectricAppViewModel.swift
//  EmonCMSiOS
//
//  Created by Matt Galloway on 14/09/2016.
//  Copyright © 2016 Matt Galloway. All rights reserved.
//

import Foundation

import RxSwift
import RxCocoa
import RealmSwift

final class MyElectricAppViewModel {

  enum MyElectricAppError: Error {
    case generic
    case notConfigured
    case updateFailed
  }

  typealias MyElectricData = (powerNow: Double, usageToday: Double, lineChartData: [DataPoint], barChartData: [DataPoint])

  private let account: Account
  private let api: EmonCMSAPI
  fileprivate let realm: Realm
  fileprivate let appData: MyElectricAppData

  // Inputs
  let active = Variable<Bool>(false)

  // Outputs
  private(set) var title: Driver<String>
  private(set) var data: Driver<MyElectricData>
  private(set) var isRefreshing: Driver<Bool>
  private(set) var isReady: Driver<Bool>
  private(set) var errors: Driver<MyElectricAppError>

  private var startOfDayKwh: DataPoint?
  private let errorsSubject = PublishSubject<MyElectricAppError>()

  init(account: Account, api: EmonCMSAPI, appDataId: String) {
    self.account = account
    self.api = api
    self.realm = account.createRealm()
    self.appData = self.realm.object(ofType: MyElectricAppData.self, forPrimaryKey: appDataId)!

    self.title = Driver.empty()
    self.data = Driver.empty()
    self.isReady = Driver.empty()
    self.errors = self.errorsSubject.asDriver(onErrorJustReturn: .generic)

    self.title = self.appData.rx
      .observe(String.self, "name")
      .map { $0 ?? "" }
      .asDriver(onErrorJustReturn: "")

    let isRefreshing = ActivityIndicator()
    self.isRefreshing = isRefreshing.asDriver()

    self.isReady = Observable.combineLatest(
      self.appData.rx.observe(String.self, #keyPath(MyElectricAppData.useFeedId)),
      self.appData.rx.observe(String.self, #keyPath(MyElectricAppData.kwhFeedId))) {
        $0 != nil && $1 != nil
      }
      .asDriver(onErrorJustReturn: false)

    let timerIfActive = self.active.asObservable()
      .distinctUntilChanged()
      .flatMapLatest { active -> Observable<()> in
        if (active) {
          return Observable<Int>.interval(10.0, scheduler: MainScheduler.asyncInstance)
            .becomeVoid()
            .startWith(())
        } else {
          return Observable.never()
        }
      }

    let feedsChangedSignal = Observable.combineLatest(self.appData.rx.observe(String.self, "useFeedId"), self.appData.rx.observe(String.self, "kwhFeedId")) {
        ($0, $1)
      }
      .distinctUntilChanged {
        $0.0 == $1.0 && $0.1 == $1.1
      }
      .skip(1) // Skip 1 because we only want to be notified when this changes after the first time the signal is created
      .becomeVoid()

    let refreshSignal = Observable.of(timerIfActive, feedsChangedSignal)
      .merge()

    self.data = refreshSignal
      .flatMapFirst { [weak self] () -> Observable<MyElectricData> in
        guard let strongSelf = self else { return Observable.empty() }
        return strongSelf.update()
          .catchError { [weak self] error in
            let typedError = error as? MyElectricAppError ?? .generic
            self?.errorsSubject.onNext(typedError)
            return Observable.empty()
          }
          .trackActivity(isRefreshing)
      }
      .asDriver(onErrorJustReturn: MyElectricData(powerNow: 0.0, usageToday: 0.0, lineChartData: [], barChartData: []))
  }

  func feedListHelper() -> FeedListHelper {
    return FeedListHelper(account: self.account, api: self.api)
  }

  private func update() -> Observable<MyElectricData> {
    guard let useFeedId = self.appData.useFeedId, let kwhFeedId = self.appData.kwhFeedId else {
      return Observable.error(MyElectricAppError.notConfigured)
    }

    return Observable.zip(
      self.fetchPowerNowAndUsageToday(useFeedId: useFeedId, kwhFeedId: kwhFeedId),
      self.fetchLineChartHistory(useFeedId: useFeedId),
      self.fetchBarChartHistory(kwhFeedId: kwhFeedId))
    {
      (powerNowAndUsageToday, lineChartData, barChartData) in
      return MyElectricData(powerNow: powerNowAndUsageToday.0,
                            usageToday: powerNowAndUsageToday.1,
                            lineChartData: lineChartData,
                            barChartData: barChartData)
    }
  }

  private func fetchPowerNowAndUsageToday(useFeedId: String, kwhFeedId: String) -> Observable<(Double, Double)> {
    let calendar = Calendar.current
    let dateComponents = calendar.dateComponents([.year, .month, .day], from: Date())
    let midnightToday = calendar.date(from: dateComponents)!

    let startOfDayKwhSignal: Observable<DataPoint>
    if let startOfDayKwh = self.startOfDayKwh, startOfDayKwh.time == midnightToday {
      startOfDayKwhSignal = Observable.just(startOfDayKwh)
    } else {
      startOfDayKwhSignal = self.api.feedData(self.account, id: kwhFeedId, at: midnightToday, until: midnightToday + 1, interval: 1)
        .map { $0[0] }
        .do(onNext: { [weak self] in
          guard let strongSelf = self else { return }
          strongSelf.startOfDayKwh = $0
        })
    }

    let feedValuesSignal = self.api.feedValue(self.account, ids: [useFeedId, kwhFeedId])

    return Observable.zip(startOfDayKwhSignal, feedValuesSignal) { (startOfDayUsage, feedValues) in
      guard let use = feedValues[useFeedId], let useKwh = feedValues[kwhFeedId] else { return (0.0, 0.0) }

      return (use, useKwh - startOfDayUsage.value)
    }
  }

  private func fetchLineChartHistory(useFeedId: String) -> Observable<[DataPoint]> {
    let endTime = Date()
    let startTime = endTime - (60 * 60 * 8)
    let interval = Int(floor((endTime.timeIntervalSince1970 - startTime.timeIntervalSince1970) / 1500))

    return self.api.feedData(self.account, id: useFeedId, at: startTime, until: endTime, interval: interval)
  }

  private func fetchBarChartHistory(kwhFeedId: String) -> Observable<[DataPoint]> {
    let daysToDisplay = 15 // Needs to be 1 more than we actually want to ensure we get the right data
    let endTime = Date()
    let startTime = endTime - Double(daysToDisplay * 86400)

    return self.api.feedDataDaily(self.account, id: kwhFeedId, at: startTime, until: endTime)
      .map { dataPoints in
        guard dataPoints.count > 1 else { return [] }

        var newDataPoints: [DataPoint] = []
        var lastValue: Double = dataPoints[0].value
        for i in 1..<dataPoints.count {
          let thisDataPoint = dataPoints[i]
          let differenceValue = thisDataPoint.value - lastValue
          lastValue = thisDataPoint.value
          newDataPoints.append(DataPoint(time: thisDataPoint.time, value: differenceValue))
        }

        return newDataPoints
      }
  }

}

extension MyElectricAppViewModel {

  private enum ConfigKeys: String {
    case name
    case useFeedId
    case kwhFeedId
  }

  func configFields() -> [AppConfigField] {
    let fields = [
      AppConfigField(id: "name", name: "Name", type: .string),
      AppConfigField(id: "useFeedId", name: "Use Feed", type: .feed),
      AppConfigField(id: "kwhFeedId", name: "kWh Feed", type: .feed),
    ]
    return fields
  }

  func configData() -> [String:Any] {
    var data: [String:Any] = [:]

    data[ConfigKeys.name.rawValue] = self.appData.name
    if let feedId = self.appData.useFeedId {
      data[ConfigKeys.useFeedId.rawValue] = feedId
    }
    if let feedId = self.appData.kwhFeedId {
      data[ConfigKeys.kwhFeedId.rawValue] = feedId
    }

    return data
  }

  func updateWithConfigData(_ data: [String:Any]) {
    do {
      try self.realm.write {
        if let name = data[ConfigKeys.name.rawValue] as? String {
          self.appData.name = name
        }
        if let feedId = data[ConfigKeys.useFeedId.rawValue] as? String {
          self.appData.useFeedId = feedId
        }
        if let feedId = data[ConfigKeys.kwhFeedId.rawValue] as? String {
          self.appData.kwhFeedId = feedId
        }
      }
    } catch {
      AppLog.error("Failed to save app data: \(error)")
    }
  }

}
