"""
Market Spread App

Setting up a market spread run (in order):
1) reports sink:
nc -l 127.0.0.1 7002 >> /dev/null

2) metrics sink:
nc -l 127.0.0.1 7003 >> /dev/null

3) market spread app:
./market-spread-jr -i 127.0.0.1:7000,127.0.0.1:7001 -o 127.0.0.1:7002 -m 127.0.0.1:7003 -c 127.0.0.1:6000 -d 127.0.0.1:6001 -f ../../demos/marketspread/initial-nbbo-fixish.msg -e 10000000 -n node-name --ponythreads=4

4) orders:
giles/sender/sender -b 127.0.0.1:7001 -m 5000000 -s 300 -i 5_000_000 -f demos/marketspread/350k-orders-fixish.msg -r --ponythreads=1 -y -g 57

5) nbbo:
giles/sender/sender -b 127.0.0.1:7000 -m 10000000 -s 300 -i 2_500_000 -f demos/marketspread/350k-nbbo-fixish.msg -r --ponythreads=1 -y -g 46

Baseline using Junior metrics (on John's 4 core, Sean sees similar):
20-30mb of memory used
70k/sec Trades throughput
120-140k/sec NBBO throughput
"""
use "collections"
use "net"
use "time"
use "buffered"
use "sendence/bytes"
use "sendence/fix"
use "sendence/new-fix"
use "sendence/hub"
use "sendence/epoch"
use "wallaroo"
use "wallaroo/metrics"
use "wallaroo/tcp-source"
use "wallaroo/topology"

actor Main
  new create(env: Env) =>
    try
      let symbol_data_partition = Partition[Symboly val, String](
        SymbolPartitionFunction, LegalSymbols.symbols)

      let application = recover val
        Application("Market Spread App")
          .new_pipeline[FixNbboMessage val, None](
            "Nbbo", FixNbboFrameHandler)
            .to_state_partition[Symboly val, String, None,
               SymbolData](UpdateNbbo, SymbolDataBuilder, "symbol-data",
               symbol_data_partition)
            .done()
          .new_pipeline[FixOrderMessage val, OrderResult val](
            "Orders", FixOrderFrameHandler)
            // .to[FixOrderMessage val](IdentityBuilder)
            // .to[FixOrderMessage val](IdentityBuilder)
            .to_state_partition[Symboly val, String, 
              (OrderResult val | None), SymbolData](CheckOrder, 
              SymbolDataBuilder, "symbol-data", symbol_data_partition)
            .to_sink(OrderResultEncoder, recover [0] end)     
      end
      Startup(env, application)
    else
      env.out.print("Couldn't build topology")
    end

primitive Identity
  fun name(): String => "identity"
  fun apply(r: FixOrderMessage val): FixOrderMessage val =>
    @printf[I32]("Identity\n".cstring())
    r

primitive IdentityBuilder
  fun apply(): Computation[FixOrderMessage val, FixOrderMessage val] val =>
    Identity
 
interface Symboly
  fun symbol(): String

class val SymbolDataBuilder
  fun apply(): SymbolData => SymbolData
  fun name(): String => "Market Data"

class SymbolData
  var should_reject_trades: Bool = true
  var last_bid: F64 = 0
  var last_offer: F64 = 0

primitive UpdateNbbo is StateComputation[FixNbboMessage val, None, SymbolData]
  fun name(): String => "Update NBBO"

  fun apply(msg: FixNbboMessage val, state: SymbolData): None =>
    let offer_bid_difference = msg.offer_px() - msg.bid_px()

    state.should_reject_trades = (offer_bid_difference >= 0.05) or
      ((offer_bid_difference / msg.mid()) >= 0.05)

    state.last_bid = msg.bid_px()
    state.last_offer = msg.offer_px()
    None

class CheckOrder is StateComputation[FixOrderMessage val, OrderResult val, 
  SymbolData]
  fun name(): String => "Check Order against NBBO"

  fun apply(msg: FixOrderMessage val, state: SymbolData): 
    (OrderResult val | None) =>
    if state.should_reject_trades then
      OrderResult(msg, state.last_bid, state.last_offer,
        Epoch.nanoseconds())
    else
      None
    end

primitive FixOrderFrameHandler is FramedSourceHandler[FixOrderMessage val]
  fun header_length(): USize =>
    4

  fun payload_length(data: Array[U8] iso): USize ? =>
    Bytes.to_u32(data(0), data(1), data(2), data(3)).usize()

  fun decode(data: Array[U8] val): FixOrderMessage val ? =>
    match FixishMsgDecoder(data)
    | let m: FixOrderMessage val => m
    else
      error
    end

primitive FixNbboFrameHandler is FramedSourceHandler[FixNbboMessage val]
  fun header_length(): USize =>
    4

  fun payload_length(data: Array[U8] iso): USize ? =>
    Bytes.to_u32(data(0), data(1), data(2), data(3)).usize()

  fun decode(data: Array[U8] val): FixNbboMessage val ? =>
    match FixishMsgDecoder(data)
    | let m: FixNbboMessage val => m
    else
      error
    end

// class SymbolRouter is Router[(FixNbboMessage val | FixOrderMessage val),
//   Step tag]
//   let _routes: Map[String, Step tag] val

//   new iso create(routes: Map[String, Step tag] val) =>
//     _routes = routes

//   fun route(input: (FixNbboMessage val | FixOrderMessage val)): 
//     (Step tag | None) 
//   =>
//     if _routes.contains(input.symbol()) then
//       try
//         _routes(input.symbol())
//       end
//     end

primitive SymbolPartitionFunction
  fun apply(input: Symboly val): String 
  =>
    input.symbol()

class OrderResult
  let order: FixOrderMessage val
  let bid: F64
  let offer: F64
  let timestamp: U64

  new val create(order': FixOrderMessage val,
    bid': F64,
    offer': F64,
    timestamp': U64)
  =>
    order = order'
    bid = bid'
    offer = offer'
    timestamp = timestamp'

  fun string(): String =>
    (order.symbol().clone().append(", ")
      .append(order.order_id()).append(", ")
      .append(order.account().string()).append(", ")
      .append(order.price().string()).append(", ")
      .append(order.order_qty().string()).append(", ")
      .append(order.side().string()).append(", ")
      .append(bid.string()).append(", ")
      .append(offer.string()).append(", ")
      .append(timestamp.string())).clone()

primitive OrderResultEncoder
  fun apply(r: OrderResult val, wb: Writer = Writer): Array[ByteSeq] val =>
    @printf[I32]((r.order.order_id() + " " + r.order.symbol() + "\n").cstring())
    //Header (size == 55 bytes)
    let msgs_size: USize = 1 + 4 + 6 + 4 + 8 + 8 + 8 + 8 + 8
    wb.u32_be(msgs_size.u32())
    //Fields
    match r.order.side()
    | Buy => wb.u8(SideTypes.buy())
    | Sell => wb.u8(SideTypes.sell())
    end
    wb.u32_be(r.order.account())
    wb.write(r.order.order_id().array()) // assumption: 6 bytes
    wb.write(r.order.symbol().array()) // assumption: 4 bytes
    wb.f64_be(r.order.order_qty())
    wb.f64_be(r.order.price())
    wb.f64_be(r.bid)
    wb.f64_be(r.offer)
    wb.u64_be(r.timestamp)
    let payload = wb.done()
    HubProtocol.payload("rejected-orders", "reports:market-spread", 
      consume payload, wb)

class LegalSymbols
  let symbols: Array[String] val

  new create() =>
    symbols = recover      
      [
"AA",
"BAC",
"AAPL",
"FCX",
"SUNE",
"FB",
"RAD",
"INTC",
"GE",
"WMB",
"S",
"ATML",
"YHOO",
"F",
"T",
"MU",
"PFE",
"CSCO",
"MEG",
"HUN",
"GILD",
"MSFT",
"SIRI",
"SD",
"C",
"NRF",
"TWTR",
"ABT",
"VSTM",
"NLY",
"AMAT",
"X",
"NFLX",
"SDRL",
"CHK",
"KO",
"JCP",
"MRK",
"WFC",
"XOM",
"KMI",
"EBAY",
"MYL",
"ZNGA",
"FTR",
"MS",
"DOW",
"ATVI",
"ORCL",
"JPM",
"FOXA",
"HPQ",
"JBLU",
"RF",
"CELG",
"HST",
"QCOM",
"AKS",
"EXEL",
"ABBV",
"CY",
"VZ",
"GRPN",
"HAL",
"GPRO",
"CAT",
"OPK",
"AAL",
"JNJ",
"XRX",
"GM",
"MHR",
"DNR",
"PIR",
"MRO",
"NKE",
"MDLZ",
"V",
"HLT",
"TXN",
"SWN",
"AGN",
"EMC",
"CVX",
"BMY",
"SLB",
"SBUX",
"NVAX",
"ZIOP",
"NE",
"COP",
"EXC",
"OAS",
"VVUS",
"BSX",
"SE",
"NRG",
"MDT",
"WFM",
"ARIA",
"WFT",
"MO",
"PG",
"CSX",
"MGM",
"SCHW",
"NVDA",
"KEY",
"RAI",
"AMGN",
"HTZ",
"ZTS",
"USB",
"WLL",
"MAS",
"LLY",
"WPX",
"CNW",
"WMT",
"ASNA",
"LUV",
"GLW",
"BAX",
"HCA",
"NEM",
"HRTX",
"BEE",
"ETN",
"DD",
"XPO",
"HBAN",
"VLO",
"DIS",
"NRZ",
"NOV",
"MET",
"MNKD",
"MDP",
"DAL",
"XON",
"AEO",
"THC",
"AGNC",
"ESV",
"FITB",
"ESRX",
"BKD",
"GNW",
"KN",
"GIS",
"AIG",
"SYMC",
"OLN",
"NBR",
"CPN",
"TWO",
"SPLS",
"AMZN",
"UAL",
"MRVL",
"BTU",
"ODP",
"AMD",
"GLNG",
"APC",
"HL",
"PPL",
"HK",
"LNG",
"CVS",
"CYH",
"CCL",
"HD",
"AET",
"CVC",
"MNK",
"FOX",
"CRC",
"TSLA",
"UNH",
"VIAB",
"P",
"AMBA",
"SWFT",
"CNX",
"BWC",
"SRC",
"WETF",
"CNP",
"ENDP",
"JBL",
"YUM",
"MAT",
"PAH",
"FINL",
"BK",
"ARWR",
"SO",
"MTG",
"BIIB",
"CBS",
"ARNA",
"WYNN",
"TAP",
"CLR",
"LOW",
"NYMT",
"AXTA",
"BMRN",
"ILMN",
"MCD",
"NAVI",
"FNFG",
"AVP",
"ON",
"DVN",
"DHR",
"OREX",
"CFG",
"DHI",
"IBM",
"HCP",
"UA",
"KR",
"AES",
"STWD",
"BRCM",
"APA",
"STI",
"MDVN",
"EOG",
"QRVO",
"CBI",
"CL",
"ALLY",
"CALM",
"SN",
"FEYE",
"VRTX",
"KBH",
"ADXS",
"HCBK",
"OXY",
"TROX",
"NBL",
"MON",
"PM",
"MA",
"HDS",
"EMR",
"CLF",
"AVGO",
"INCY",
"M",
"PEP",
"WU",
"KERX",
"CRM",
"BCEI",
"PEG",
"NUE",
"UNP",
"SWKS",
"SPW",
"COG",
"BURL",
"MOS",
"CIM",
"CLNY",
"BBT",
"UTX",
"LVS",
"DE",
"ACN",
"DO",
"LYB",
"MPC",
"SNDK",
"AGEN",
"GGP",
"RRC",
"CNC",
"PLUG",
"JOY",
"HP",
"CA",
"LUK",
"AMTD",
"GERN",
"PSX",
"LULU",
"SYY",
"HON",
"PTEN",
"NWSA",
"MCK",
"SVU",
"DSW",
"MMM",
"CTL",
"BMR",
"PHM",
"CIE",
"BRCD",
"ATW",
"BBBY",
"BBY",
"HRB",
"ISIS",
"NWL",
"ADM",
"HOLX",
"MM",
"GS",
"AXP",
"BA",
"FAST",
"KND",
"NKTR",
"ACHN",
"REGN",
"WEN",
"CLDX",
"BHI",
"HFC",
"GNTX",
"GCA",
"CPE",
"ALL",
"ALTR",
"QEP",
"NSAM",
"ITCI",
"ALNY",
"SPF",
"INSM",
"PPHM",
"NYCB",
"NFX",
"TMO",
"TGT",
"GOOG",
"SIAL",
"GPS",
"MYGN",
"MDRX",
"TTPH",
"NI",
"IVR",
"SLH"]
end