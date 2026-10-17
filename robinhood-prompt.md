You are helping me manage trades in my own Robinhood account using the robinhood-trading tools.
Follow these steps in order. Before you place, cancel, or replace any order, show me a summary
table of what you plan to do and wait for me to type "CONFIRM".

STEP 1 — Account check
- Call get_accounts and get_portfolio. Report buying power, and stop if it is under $300.
- Call get_equity_positions and get_equity_orders (open orders only). List every holding and
  every open stop or stop-limit order.

STEP 2 — Pick one stock from today's top gainers
- Fetch https://finance.yahoo.com/markets/stocks/gainers/ . If Yahoo blocks the request or the
  page has no usable data, use Robinhood's run_scan / preview_scan to get today's top % gainers.
- Drop any candidate that has: price under $5, market cap under $2B, average volume under 1M,
  earnings in the next 3 days (get_earnings_calendar), or that is not tradable (get_equity_tradability).
- From the rest, pick ONE. Check get_equity_quotes, get_equity_fundamentals,
  get_equity_technical_indicators (RSI, distance from VWAP) and get_equity_analyst_ratings.
  Prefer a stock that is not extremely overbought (RSI below 80). Give me 2–3 sentences on why.

STEP 3 — Buy $300 of it
- Shares = floor(300 / current ask) in WHOLE shares, so a stop order can be attached later.
  If one share costs more than $300, pick the next candidate.
- Use review_equity_order for a LIMIT buy at the current ask + 0.2% (no market orders),
  time-in-force = day. Show me the review, then place_equity_order after I confirm.
- Poll get_equity_orders until the order fills. If it hasn't filled in 5 minutes, cancel it and tell me.

STEP 4 — Stop loss on the new position
- Once it fills, place a STOP-LIMIT SELL for the full share count:
    stop price  = fill price × 0.99   (1% below)
    limit price = stop price × 0.995  (gives a little room so it can fill)
    time-in-force = GTC
- Round prices to $0.01.

STEP 5 — Reset stops on every existing holding
- For each equity position (whole shares only; list fractional shares separately and skip them):
    a. Get the current price from get_equity_quotes.
    b. New stop = current price × 0.99, new limit = new stop × 0.995.
    c. If an existing stop order for that symbol has a HIGHER stop price than the new one,
       keep it (never lower a stop) and mark it "kept".
    d. Otherwise cancel_equity_order the old stop first, check it shows cancelled,
       then place the new GTC stop-limit sell for the full share quantity.
- Show the whole plan as one table before doing anything:
  Symbol | Qty | Current price | Old stop | New stop | New limit | Action

STEP 6 — Final report
- Re-check get_equity_orders and list every active stop order so I can verify that every
  position is covered. Flag anything that failed.

Rules: never use margin, never exceed $300 for the new buy, never place market orders,
never sell anything except through the stop orders above, and stop and ask me if anything
is unclear or a tool call fails.
