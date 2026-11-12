//! Domain entities.
//!
//! One file for the whole vocabulary: these are the shapes the database
//! rows decode into and the shapes the view renders. Two house rules
//! hold everywhere in this file:
//!
//!   * **Money is `i64` minor units.** Never a float. A rupee, a cent or
//!     a yen is an integer; the currency decides the scale. Eatery v1 kept
//!     money in REAL columns and lost cents to rounding - that class of bug
//!     does not get a second chance here.
//!   * **Time is `i64` epoch milliseconds, UTC.** Every timestamp in the
//!     database is the same shape, so ordering and range queries need no
//!     per-column knowledge.
//!
//! Text is `[]const u8` owned by the loader, never by the model: rows are
//! decoded into an arena the view owns and dropped with it.

const std = @import("std");

/// The three kinds of sale a restaurant runs. The POS picks one per
/// order; the kitchen and the receipt both care.
pub const OrderType = enum(i64) {
    dine_in = 0,
    take_away = 1,
    delivery = 2,

    pub fn label(self: OrderType) []const u8 {
        return switch (self) {
            .dine_in => "Dine in",
            .take_away => "Take away",
            .delivery => "Delivery",
        };
    }
};

/// Order lifecycle. The transition table lives in `nextStatus`, in
/// `core/update.zig`. The ordinals are the database's `status` column and
/// never change; only the words below do.
pub const OrderStatus = enum(i64) {
    pending = 0,
    preparing = 1,
    ready = 2,
    served = 3,
    completed = 4,
    voided = 5,
    held = 6,

    /// What the ticket is called on a board. These are the words the
    /// floor uses, not the words the workflow engine uses: a cook says
    /// "new" and "cooking", and a closed ticket has taken its money.
    pub fn label(self: OrderStatus) []const u8 {
        return switch (self) {
            .pending => "New",
            .preparing => "Cooking",
            .ready => "Ready",
            .served => "Served",
            .completed => "Closed",
            .voided => "Voided",
            .held => "Held",
        };
    }

    /// What pressing the board's button from here actually does. The
    /// caption names the move, so a tap is never a mystery. An empty
    /// label means there is no move left to make - the ticket is closed
    /// or voided - and the board hides the button rather than showing a
    /// blank one.
    pub fn actionLabel(self: OrderStatus) []const u8 {
        return switch (self) {
            .pending => "Start cooking",
            .preparing => "Mark ready",
            .ready => "Hand off",
            .served => "Close ticket",
            .completed, .voided, .held => "",
        };
    }

    /// True while there is a move left to make.
    pub fn advanceable(self: OrderStatus) bool {
        return self.actionLabel().len > 0;
    }

    /// The state a stored ordinal names. A number the database cannot
    /// produce reads as a new ticket: the safest thing to do with a
    /// state this app does not recognise is to treat it as unfinished.
    pub fn fromCode(code: i64) OrderStatus {
        return std.enums.fromInt(OrderStatus, code) orelse .pending;
    }
};

/// How a product is prepared. Drives the KDS grouping and whether stock
/// is decremented.
pub const ProductType = enum(i64) {
    dish = 0,
    beverage = 1,
    dessert = 2,
    combo = 3,
    service = 4,

    pub fn label(self: ProductType) []const u8 {
        return switch (self) {
            .dish => "Dish",
            .beverage => "Beverage",
            .dessert => "Dessert",
            .combo => "Combo",
            .service => "Service",
        };
    }
};

/// Vegetarian / non-vegetarian / egg - the usual kitchen markings.
pub const FoodType = enum(i64) {
    non_veg = 0,
    veg = 1,
    egg = 2,
    jain = 3,

    pub fn label(self: FoodType) []const u8 {
        return switch (self) {
            .non_veg => "Non-veg",
            .veg => "Veg",
            .egg => "Egg",
            .jain => "Jain",
        };
    }
};

pub const TableStatus = enum(i64) {
    free = 0,
    occupied = 1,
    reserved = 2,
    dirty = 3,

    pub fn label(self: TableStatus) []const u8 {
        return switch (self) {
            .free => "Free",
            .occupied => "Occupied",
            .reserved => "Reserved",
            .dirty => "Needs cleaning",
        };
    }
};

pub const PaymentMode = enum(i64) {
    cash = 0,
    card = 1,
    upi = 2,
    wallet = 3,
    credit = 4,

    pub fn label(self: PaymentMode) []const u8 {
        return switch (self) {
            .cash => "Cash",
            .card => "Card",
            .upi => "UPI",
            .wallet => "Wallet",
            .credit => "On account",
        };
    }
};

/// The company the device belongs to. One company per database in Restaurant OS -
/// the multi-company story from v1 was never used and cost real time.
pub const Company = struct {
    id: i64,
    name: []const u8,
    currency_code: []const u8,
    currency_symbol: []const u8,
    tax_inclusive: bool,
    address: []const u8,
    phone: []const u8,
    tax_number: []const u8,
};

/// A staff member. The credential hash never enters this struct: the
/// login check happens in SQL, and only the id and display name come
/// back.
pub const Employee = struct {
    id: i64,
    name: []const u8,
    role: i64,
    /// The role, as text.
    role_label: []const u8,
    active: bool,
    /// How this person signs in. Defaults to a PIN, which is what every
    /// row written before the column existed is.
    auth_kind: CredentialKind = .pin,
    /// That, as the screen says it. The list binds a field, not a method.
    credential_label: []const u8 = CredentialKind.pin.label(),
};

pub const ProductCategory = struct {
    id: i64,
    name: []const u8,
    sort_order: i64,
};

pub const Product = struct {
    id: i64,
    category_id: i64,
    name: []const u8,
    /// The food marking, as text: the markup binds fields, not methods.
    food_label: []const u8,
    /// Price in minor units (cents, paise, yen...).
    price_minor: i64,
    product_type: ProductType,
    food_type: FoodType,
    tax_slab_id: i64,
    stock_qty: i64,
    active: bool,
};

pub const DiningTableCategory = struct {
    id: i64,
    name: []const u8,
};

pub const DiningTable = struct {
    id: i64,
    category_id: i64,
    name: []const u8,
    status: TableStatus,
    /// The status as text, resolved at decode time - the markup binds
    /// fields, not methods.
    status_label: []const u8,
    seats: i64,
    /// Position on the floor plan, in grid cells.
    pos_x: i64,
    pos_y: i64,
};

/// A category of dining table: "Main room", "Terrace", "Bar".
pub const TableCategory = struct {
    id: i64,
    name: []const u8,
};

pub const Customer = struct {
    id: i64,
    name: []const u8,
    phone: []const u8,
    email: []const u8,
    loyalty_points: i64,
    /// The points, as the row shows them.
    points_label: []const u8,
};

pub const TaxSlab = struct {
    id: i64,
    name: []const u8,
    /// Rate in basis points (5% == 500).
    rate_bps: i64,
    inclusive: bool,
    active: bool,
    /// "Inclusive" or "Exclusive", as the row shows it.
    tax_label: []const u8,
};

pub const KdsStation = struct {
    id: i64,
    name: []const u8,
    sort_order: i64,
};

/// The roles an employee can have.
pub const EmployeeRole = enum(i64) {
    admin = 0,
    waiter = 1,
    kitchen = 2,
    display = 3,

    pub fn label(self: EmployeeRole) []const u8 {
        return switch (self) {
            .admin => "Admin",
            .waiter => "Waiter",
            .kitchen => "Kitchen",
            .display => "Display",
        };
    }

    /// The stored role, from the number the database holds. Null when
    /// the number is not a role this app knows: a database value is
    /// untrusted, and a role the app does not know is not a role.
    pub fn fromInt(code: i64) ?EmployeeRole {
        return std.enums.fromInt(EmployeeRole, code);
    }
};

/// How a person proves who they are at a till. A PIN is short, numeric and
/// tapped on a screen in front of a queue; a password is longer, mixed and
/// typed. The kind is the person's, not the device's: the same manager taps
/// a code at the counter and types one at the office machine.
pub const CredentialKind = enum(i64) {
    pin = 0,
    password = 1,

    pub fn label(self: CredentialKind) []const u8 {
        return switch (self) {
            .pin => "PIN",
            .password => "Password",
        };
    }

    /// The stored kind, from the number the database holds. Null when the
    /// number is not a kind this app knows - the added column has no CHECK
    /// to lean on, because SQLite refuses one on a column added after the
    /// table - so this is the only thing standing between a corrupt row and
    /// a till that offers the wrong surface.
    pub fn fromInt(code: i64) ?CredentialKind {
        return std.enums.fromInt(CredentialKind, code);
    }
};

/// A reservation for a table.
pub const Reservation = struct {
    id: i64,
    name: []const u8,
    phone: []const u8,
    guests: i64,
    reserved_at: i64,
    /// The same moment in epoch SECONDS - the markup's time() takes
    /// seconds, and a division would make it a float.
    reserved_seconds: i64,
    /// 'booked', 'seated' or 'cancelled'.
    status: i64,
    status_label: []const u8,
    notes: []const u8,
};

/// A supplier the restaurant buys from.
pub const Supplier = struct {
    id: i64,
    name: []const u8,
    phone: []const u8,
    email: []const u8,
    address: []const u8,
    gstin: []const u8,
    active: bool,
};

/// An order placed with a supplier.
pub const PurchaseOrder = struct {
    id: i64,
    order_no: []const u8,
    status: i64,
    status_label: []const u8,
    total_minor: i64,
    ordered_at: i64,
    /// The same moment in epoch SECONDS.
    ordered_seconds: i64,
    expected_at: i64,
    notes: []const u8,
};

/// A receipt or kitchen printer.
pub const Printer = struct {
    id: i64,
    name: []const u8,
    /// 'escpos' or 'system'.
    kind: []const u8,
    /// 'ble', 'tcp', 'usb' or 'file'.
    transport: []const u8,
    address: []const u8,
    /// 'receipt', 'kot' or 'report'.
    job: []const u8,
    active: bool,
};

/// A group of choices on a dish.
pub const ModifierGroup = struct {
    id: i64,
    name: []const u8,
    required: bool,
    max_select: i64,
    active: bool,
    /// "Required" or "Optional", as the row shows it.
    required_label: []const u8,
};

/// One choice inside a modifier group: "Extra cheese", "Well done".
pub const Modifier = struct {
    id: i64,
    group_id: i64,
    name: []const u8,
    /// What the choice adds to the price, in minor units. Zero is a
    /// choice that costs nothing.
    price_delta_minor: i64,
    active: bool,
};

/// A discount: a percentage, a fixed amount, or both.
pub const Discount = struct {
    id: i64,
    name: []const u8,
    percent_bps: i64,
    amount_minor: i64,
    active: bool,
    /// The discount as the row shows it: "10%" or "₹50.00".
    value_label: []const u8,
};

/// Which station cooks which product.
pub const ProductStation = struct {
    product_id: i64,
    station_id: i64,
};

/// One line of an order. Prices are frozen at the moment the order was
/// taken - a price change tomorrow must not rewrite yesterday's bills.
pub const OrderLine = struct {
    id: i64,
    order_id: i64,
    product_id: i64,
    /// The kitchen station that cooks this line.
    station_id: i64,
    product_name: []const u8,
    qty: i64,
    unit_price_minor: i64,
    tax_bps: i64,
    notes: []const u8,
};

pub const Order = struct {
    /// True when a payment has been taken for this order. An order
    /// without one is not closed, whatever its status says.
    paid: bool = false,
    id: i64,
    order_no: []const u8,
    order_type: OrderType,
    status: OrderStatus,
    /// The same state as the database's ordinal. The markup can compare
    /// a number and cannot name a bound colour token, so this is what
    /// `status-badge` picks its literal colours from.
    status_code: i64,
    /// Labels resolved at decode time: the markup binds fields.
    status_label: []const u8,
    /// The caption of the button that moves this order to the next state.
    /// Empty when there is no next state, and `advanceable` is false.
    advance_label: []const u8,
    advanceable: bool,
    type_label: []const u8,
    dining_table_id: i64,
    customer_id: i64,
    employee_id: i64,
    subtotal_minor: i64,
    tax_minor: i64,
    discount_minor: i64,
    total_minor: i64,
    placed_at: i64,
    notes: []const u8,
    /// The device that took the sale. It is the first half of the
    /// order's cross-device identity; `id` above is only this database's
    /// local key. An empty value means "this device" for a row that
    /// predates the origin columns.
    origin_device: []const u8 = "",
    /// The order's id on `origin_device`. Together with the device it
    /// names the same sale on every database.
    origin_id: i64 = 0,
};

/// A printable report of the day's takings. Kept so a device can print
/// an X report without the app being open.
pub const Shift = struct {
    id: i64,
    employee_id: i64,
    opened_at: i64,
    closed_at: i64,
    opening_cash_minor: i64,
    closing_cash_minor: i64,
    expected_cash_minor: i64,
};

/// A payment the restaurant took.
///
/// The money is in minor units, and the mode is an enum resolved to a
/// label at decode time: the markup binds fields, it does not decide
/// what cash is called.
pub const Payment = struct {
    id: i64,
    order_id: i64,
    order_no: []const u8,
    mode: PaymentMode,
    /// The name of the mode, for the view.
    mode_label: []const u8,
    amount_minor: i64,
    reference: []const u8,
    paid_at: i64,
};

/// A refund given back for a voided paid order.
pub const Refund = struct {
    id: i64,
    payment_id: i64,
    order_id: i64,
    amount_minor: i64,
    reason: []const u8,
    refunded_at: i64,
};

/// A bank ledger entry.
pub const BankLedgerEntry = struct {
    id: i64,
    account_id: i64,
    entry_type: i64,
    amount_minor: i64,
    reference: []const u8,
    created_at: i64,
};

/// An expense voucher.
pub const Expense = struct {
    id: i64,
    category_id: i64,
    amount_minor: i64,
    note: []const u8,
    spent_at: i64,
};

/// A bank account.
pub const BankAccount = struct {
    id: i64,
    name: []const u8,
    account_no: []const u8,
    active: bool,
};

/// A loyalty member.
pub const LoyaltyMember = struct {
    id: i64,
    name: []const u8,
    phone: []const u8,
    points: i64,
    active: bool,
};

/// A staff attendance entry.
pub const Attendance = struct {
    id: i64,
    employee_id: i64,
    clock_in: i64,
    clock_out: i64,
};

/// A work period: an open/close boundary for reports and cash.
pub const WorkPeriod = struct {
    id: i64,
    started_at: i64,
    ended_at: i64,
    status: i64,
    started_by: i64,
    ended_by: i64,
};

/// How the money came in, on one mode.
pub const ReportMode = struct {
    mode: PaymentMode,
    /// The name of the mode, for the view.
    mode_label: []const u8,
    count: i64,
    amount_minor: i64,
};

/// Something the restaurant counts. The stock on the shelf, as of the
/// last count.
pub const StockItem = struct {
    id: i64,
    name: []const u8,
    /// The number on the shelf. Zero is a real number, and so is a
    /// product that is not counted at all.
    stock_qty: i64,
};

/// A device that has been in this restaurant.
pub const Device = struct {
    id: []const u8,
    name: []const u8,
    role: []const u8,
    last_seen_at: i64,
};

/// One piece of the sync sidecar's state.
pub const SyncState = struct {
    key: []const u8,
    value: []const u8,
};

/// One table in the database, and how many rows it holds.
pub const TableCount = struct {
    name: []const u8,
    rows: i64,
};

/// One line of the POS cart. The cart is session state, not database
/// state: it lives in the model until the order is placed.
pub const CartLine = struct {
    product_id: i64,
    /// The product name, frozen at the moment it was added so a later
    /// price change cannot rewrite the cart.
    name: []const u8,
    price_minor: i64,
    qty: i64,
};
