# Legacy TouchscreenRestaurantPOS — extracted knowledge

Source: `TouchscreenRestaurantPOS-GST` (VB.NET/WinForms, SQL Server, production).
Goal: carry essential domain knowledge into ROS (Zig/Native SDK).

## 1. Work periods

- `WorkPeriodStart(WPStart, Status)`; active row has `Status='Active'`.
- Starting a period: mark all prior rows `Inactive`, insert new active row.
- A work period gates reports and (implicitly) stock/cash sessions.
- ROS equivalent: `work_period` table? (check ROS schema for `work_period`).

## 2. Order model (multi-type)

Legacy splits orders by service type into parallel tables:
- `RestaurantPOS_BillingInfo{EB,HD,KOT,TA}` (header)
- `RestaurantPOS_OrderedProductBill{EB,HD,KOT,TA}` (lines)
- `RestaurantPOS_OrderInfoKOT` (KOT header), `RestaurantPOS_OrderedProductKOT` (KOT lines)
- `HoldBill`/`HoldItems` (parked bills)

ROS unifies into `orders` + `order_line` with a `service_type`/`order_type` field and a status machine. Essential retained concepts:
- KOT (kitchen order ticket) is a first-class artifact, separate from the guest bill.
- A KOT can be voided (`rptVoidKOT`) and re-printed.
- Final bill can be generated from accumulated KOTs (`RestaurantPOSKOTFinalBillRecord`).
- Hold/park bills for later recall.

## 3. Stock & inventory

- Temp stock tables (`Temp_Stock`, `Temp_Stock_RM`, `Temp_Stock_Store`) are used during a sale to decrement stock tentatively.
- `Stock_Store` / `Stock_Store_Join` track on-hand by store.
- `StockAdjustment_Store` / `StockAdjustment_Warehouse` for adjustments.
- `StockTransfer` / `StockTransfer_Join` for inter-store movement.
- `Recipe` / `Recipe_Join` and `RM_*` (raw materials) link dishes to ingredients; `RM_Used`/`RM_Used_Join` record consumption.
- `Purchase` / `PurchaseOrder` + joins for procurement.
- `Product_OpeningStock` for opening balances.

ROS should keep: tentative stock decrement on order, commit on payment, adjustment & transfer, recipe/BOM consumption on sale.

## 4. Credit customers & ledger

- `CreditCustomer`, `CreditCustomerLedger`, `CreditCustomerPayment`, `CreditCustomerBalance`.
- Customer credit is a ledger (append-only entries), not a stored balance field.
- Payments settle against ledger; balance derived.

ROS maps to `customer` + ledger tables; keep derived-balance rule (Rule 3).

## 5. Accounting / banking

- `Journal`, `LedgerBook`, `Voucher`, `Bank`, `BankAccountRegistration`, `BankAccountLedger`, `FundDeposit`, `FundTransfer`, `Payment`, `Payment_Withdraw`, `Expense`/`ExpenseType`.
- Bank reconciliation is a separate module (`frmBankReconciliation`).
- Vouchers capture non-sale cash movements.

ROS: expense/voucher/bank modules are future scope; keep schema hooks.

## 6. Loyalty & promotions

- `LoyaltyMember`, `LoyaltyMemberLedgerBook`, `LoyaltySetting`.
- `Promotion`, `GiftCard`, `Wallet`.
- Loyalty is points-ledger based.

## 7. People / auth / attendance

- `EmployeeRegistration`, `UserRights` (RBAC), `ClockIN`/`ClockOUT`.
- Credentials are per-employee; sign-in method (PIN/password) is a per-person attribute — matches ROS `auth_kind`.

## 8. Printing & automation

- `Automations` table stores print automation config.
- `PosPrinterSetting` per terminal.
- KOT printing has dedicated reports (`rptRestaurantPOSKOTInvoice_Kitchen`, `rptVoidKOT`).
- Customer display (`CustomerDisplay`) on serial port.

ROS keeps printing as an effect (`fx.writeFile`/printer) and KDS replaces paper KOT.

## 9. Tax / compliance

- GST/VAT variants differ by tax regime; `TaxType` setting.
- `DeletedInvoices` / `WorkPeriod` reports for audit.

## 10. Notable UI flows worth preserving

- Hold bill → recall → settle.
- Void KOT with reason.
- Work period start/end with Z-report.
- Table assignment / available tables / waiter assignment.
- Customer display with item + balance.
- Credit customer ledger + payment.

## Mapping note

Legacy uses one SQL Server database per restaurant with ~112 tables and per-service-type order tables. ROS consolidates into 46 STRICT SQLite tables with a unified order model and an op log for sync. The legacy list above is the feature checklist; ROS schema already covers core POS, KDS, inventory, customers, payments, sync. Gaps to consider: bank reconciliation, loyalty, promotions, gift cards, vouchers, attendance, work-period Z-report.


## 11. KOT void & stock reversal (deep dive)

- `VoidBill()` (frmPOS): checks if table has other open KOTs; if only one, resets table color to green.
- Sets `RestaurantPOS_OrderInfoKOT.KOT_Status='Void'` for the ticket.
- Asks "Does the stock affected?":
  - Yes → `frmCustomDialogX.lblSet="Void KOT"` (stock reversal path).
  - No → `"Void RKOT"` (no stock reversal).
- `RawMaterialUsedDel(BillNo)` deletes `RM_Used` rows for that bill, reversing raw-material consumption.
- Every void is logged via `LogFunc(user, "void the kot having Ticket No....")`.

Essence: voiding is a first-class, audited operation with an explicit stock-impact decision. ROS KDS should preserve void + reason + stock reversal.

## 12. Raw material / recipe tracking

- `RM_Used(RM_ID, BillDate, BillNo)` records raw-material consumption per bill.
- `RawMaterialUsed` inserts one row per raw material per sale.
- `RawMaterialUsedDel` removes them on void.
- Recipes (`Recipe`/`Recipe_Join`) link a dish to raw materials; sale consumes them.

Essence: a sale decrements both finished-goods stock and raw-material stock; void reverses both.

## 13. RBAC (UserRights)

- `UserRights(UserID, ModuleName, UR_Save, UR_Update, UR_Delete, UR_View)`.
- Per-user, per-module CRUD flags; checked via `ModFunc` (`Select UR_Save ...`).
- Module list is fixed (forms); rights seeded per user.

Essence: coarse per-module CRUD, not screen-level. ROS's role-based screen gating (rbac.zig) is finer and testable; keep the module list as the permission catalog.

## 14. Credit customer settlement

- `CreditCustomerBalance` dialog handles settle; `CreditCustomerLedger` append-only.
- `MemberLedger`/`MemberLedgerDelete` show ledger entries can be removed by (LedgerNo, Label) — i.e., reversal by reference.

Essence: ledger entries are reversible by reference; balances are derived. ROS should keep reversals explicit and audited.

## 15. Work period end (Z-report)

- `frmWorkPeriod` starts a period (mark prior inactive, insert active).
- End period records `WorkPeriodEnd` linked to `WorkPeriodStart` (FK).
- Reports filter by work period date range; email report supported (`GetEmail`).

Essence: work period is a first-class aggregate boundary for reports and cash reconciliation.


## 16. Held bills (park & recall)

- `HoldBill(HoldID, Date, UserID, TaxType, BillType, CName, CNo, Address, TableNo)` + `HoldItems` (Dish, Rate, Qty, Amount, discounts, tax, TotalAmount, Notes, Category, RCost, ItemStatus).
- BillType distinguishes 'Dine In', 'Take Away', 'Express', 'Home Delivery'.
- Recall loads header + items into POS; delete on recall (`HoldBillDelete`).
- Held bills store full pricing snapshot (rates, discounts, taxes) so recall is exact.

Essence: parking is a full snapshot of an in-progress order, keyed by service type; ROS can model as order status `held` with immutable line snapshots.


## 17. Customer display

- Legacy drives a serial customer display showing item name and balance.
- ROS could expose an effect to push current item/total to a secondary display.

## 18. Service-type KOT rules

- Legacy distinguishes Dine-in/TA/HD/EB with different KOT and billing paths.
- ROS keeps a unified order model; service_type should drive KOT generation, printing and billing rules, with tests per type.
