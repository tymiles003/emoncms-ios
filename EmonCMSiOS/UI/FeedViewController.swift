//
//  FeedViewController.swift
//  EmonCMSiOS
//
//  Created by Matt Galloway on 12/09/2016.
//  Copyright © 2016 Matt Galloway. All rights reserved.
//

import UIKit

import RxSwift
import Charts

class FeedViewController: UIViewController {

  var viewModel: FeedViewModel!

  @IBOutlet var chartView: LineChartView!

  private let disposeBag = DisposeBag()

  override func viewDidLoad() {
    super.viewDidLoad()

    self.viewModel.name
      .asDriver()
      .drive(self.rx.title)
      .addDisposableTo(self.disposeBag)

    self.chartView.delegate = self
    self.chartView.dragEnabled = true
    self.chartView.descriptionText = ""
    self.chartView.drawGridBackgroundEnabled = false
    self.chartView.legend.enabled = false
    self.chartView.rightAxis.enabled = false

    let xAxis = self.chartView.xAxis
    xAxis.drawGridLinesEnabled = false
    xAxis.labelPosition = .bottom
    xAxis.valueFormatter = ChartXAxisDateFormatter()

    let yAxis = self.chartView.leftAxis
    yAxis.drawGridLinesEnabled = false
    yAxis.labelPosition = .outsideChart

    let dataSet = LineChartDataSet(yVals: nil, label: self.viewModel.name.value)
    dataSet.valueTextColor = UIColor.lightGray
    dataSet.drawCirclesEnabled = false
    dataSet.drawFilledEnabled = true
    dataSet.drawValuesEnabled = false

    let data = LineChartData()
    data.addDataSet(dataSet)
    self.chartView.data = data
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    self.refresh()
  }

  private func refresh() {
    let timeRange = Double(60 * 60 * 24)
    let endDate = Date()
    let startDate = endDate - timeRange
    let interval = Int(ceil(timeRange / Double(self.chartView.bounds.width)))
    self.viewModel.fetchData(at: startDate, until: endDate, interval: interval)
      .observeOn(MainScheduler.instance)
      .subscribe(
        onNext: { [weak self] (feedDataPoints) in
          guard let strongSelf = self else { return }

          guard let data = strongSelf.chartView.data,
            let dataSet = data.getDataSetByIndex(0) else {
              return
          }

          data.xVals = []
          dataSet.clear()

          for (i, point) in feedDataPoints.enumerated() {
            data.addXValue("\(point.time.timeIntervalSince1970)")

            let yDataEntry = ChartDataEntry(value: point.value, xIndex: i)
            data.addEntry(yDataEntry, dataSetIndex: 0)
          }

          data.notifyDataChanged()
          strongSelf.chartView.notifyDataSetChanged()
        },
        onError: { (error) in
          // TODO
      })
      .addDisposableTo(self.disposeBag)
  }

}

extension FeedViewController: ChartViewDelegate {

  // TODO: Handle panning, etc

}
