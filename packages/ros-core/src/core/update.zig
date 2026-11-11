//! The update function: the only place state changes.
//!
//! Every arm here answers one question - "the world said this, so what
//! is true now?" - and nothing else. The markup dispatches messages;
//! this function decides what they mean. No I/O happens here directly:
//! anything that touches the world goes through the effects channel
//! (`fx`), and anything that comes back arrives as another message.

const std = @import("std");
const native_sdk = @import("native_sdk");

const model_mod = @import("model.zig");
const msg_mod = @import("msg.zig");
const net_bridge = @import("net_bridge.zig");
const nav = @import("navigation.zig");
const rbac = @import("rbac.zig");
const domain = @import("../domain/models.zig");
const repos = @import("../data/repos.zig");
const page = @import("../data/page.zig");
const auth = @import("../data/auth.zig");

const Model = model_mod.Model;
const Msg = msg_mod.Msg;
const Role = nav.Role;
const Screen = nav.Screen;
const canvas = native_sdk.canvas;
const Effects = native_sdk.Effects(Msg);

/// The clock tick. A repeating timer keeps `now_ms` fresh so the
/// kitchen board can show how long a ticket has been waiting.
pub const clock_timer_key: u64 = 100;

/// Boot effects: the clock timer and the first read of the database.
pub fn boot(model: *Model, fx: *Effects) void {
    model.now_ms = fx.wallMs();

    // The wire. The channel is opened here because this is the loop
    // thread's first turn; the net thread is already listening and is
    // waiting for this handle before it posts anything.
    net_bridge.open(fx);

    fx.startTimer(.{
        .key = clock_timer_key,
        .interval_ms = 1000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    // The first read: the settings the app needs before it can sign
    // anybody in, and the company - an empty database means a fresh
    // installation, and the app opens on the setup screen.
    repos.loadConfig(model, fx);
    // What this device looks like, read with the rest of the settings.
    // It is a preference rather than a record, so a database that does
    // not have it is not an error: the device draws its default.
    repos.loadTheme(model, fx);
    // The pairing token, read with the other settings and for the same
    // reason the salt is read at boot: the wire is already listening, and
    // the value it checks a peer against has to be in hand before the
    // first request, not after it.
    repos.loadPairing(model, fx);
    repos.loadCompany(model, fx);
    // The people who work here, because the picker asks who is using
    // the device. A person signs in; a device signs in by being the
    // device. The list is read here, before anybody signs in, because
    // the picker comes first.
    repos.loadEmployees(model, fx);
    // The tax slabs are read with the rest of the business's settings:
    // a sale's tax is worked out from them, and a sale that is placed
    // before they arrive would be taxed at nothing.
    repos.loadTaxSlabs(model, fx);
    // And the number of tables the database really has. A database
    // from a newer app is one this version must not write to, and the
    // only way to know is to count what is there.
    repos.loadDbTableCount(model, fx);
}

/// The employee with this id, from the list the picker shows.
fn findEmployee(model: *const Model, id: i64) ?domain.Employee {
    for (model.employees) |employee| {
        if (employee.id == id) return employee;
    }
    return null;
}

/// Put a person in front of the sign-in gate: who they are, and how
/// they prove it.
///
/// Two things reach a gate - the picker choosing a person, and a
/// session ending on the gate of the person who was using it - and both
/// ask the row, so the surface is built from the person rather than
/// from whatever the screen was showing before.
fn choose_sign_in(model: *Model, employee: domain.Employee) void {
    model.sign_in_employee_id = employee.id;
    const name_len = @min(employee.name.len, model.sign_in_employee_name_buf.len);
    @memcpy(model.sign_in_employee_name_buf[0..name_len], employee.name[0..name_len]);
    model.sign_in_employee_name_len = name_len;
    model.credential_kind = employee.auth_kind;
}

/// A new order on the board gets a sound. The kitchen hears the sale
/// without looking at the screen - and the cashier hears it too, which
/// is how a second cashier knows a table needs serving.
///
/// "New" is the local order number, not the row id. A remote order is
/// stored under a negative id, so the highest id never moves when a
/// waiter's ticket arrives from another device; the order number is a
/// sequence the database assigns to every order, local or synced.
fn announceNewOrder(model: *Model, fx: *Effects) void {
    var newest: i64 = model.last_seen_order_no;
    for (model.orders) |order| {
        const number = std.fmt.parseInt(i64, order.order_no, 10) catch 0;
        if (number > newest) newest = number;
    }
    // The first board of the shift is where the kitchen starts
    // watching, so its orders are not new sales. An empty first board
    // still counts as primed: the first order after it is a sale.
    if (!model.board_primed) {
        model.board_primed = true;
        model.last_seen_order_no = newest;
        return;
    }
    if (newest <= model.last_seen_order_no) return;
    model.last_seen_order_no = newest;
    fx.playAudio(.{
        .key = repos.key_chime,
        .path = "assets/chime.wav",
        .on_event = Effects.audioMsg(.audio_event),
    });
}

/// A payment reports success even when its guards found a late plate or
/// a ticket that moved, because the transaction itself is healthy. The
/// board is the truth: only a payment row on the order means the money
/// landed. Check it before leaving the confirmation screen.
fn settlePayment(model: *Model, fx: *Effects) void {
    const id = model.payment_check_id;
    if (id == 0) return;
    model.payment_check_id = 0;
    const order = findOrder(model, id) orelse {
        // Voided while the cashier was paying. There is no bill left to
        // charge, and the order list is the right place to be.
        model.payment_error = "";
        model.error_text = "That order is no longer on the board";
        go(model, .orders);
        return;
    };
    if (!order.paid) {
        model.payment_error = "The bill changed - check the total and take the payment again";
        return;
    }
    model.payment_error = "";
    go(model, .orders);
    net_bridge.notify();
    repos.maybeCompact(model, fx);
}

/// Keep the waiter's cart in step with the database: the lines of the
/// order they are serving, with their names copied (the shared
/// order-line buffer is reset on every read).
fn keepActiveOrder(model: *Model) void {
    if (model.active_order_id == 0) {
        model.active_lines = &.{};
        return;
    }
    var count: usize = 0;
    for (model.order_lines) |line| {
        if (line.order_id == model.active_order_id) count += 1;
    }
    model.waiter_lines_buf.reset();
    const list = model.waiter_lines_buf.allocSlice(domain.OrderLine, count) orelse {
        model.active_lines = &.{};
        return;
    };
    var index: usize = 0;
    for (model.order_lines) |line| {
        if (line.order_id != model.active_order_id) continue;
        list[index] = .{
            .id = line.id,
            .order_id = line.order_id,
            .product_id = line.product_id,
            .station_id = line.station_id,
            .product_name = model.waiter_lines_buf.dupe(line.product_name) orelse "",
            .qty = line.qty,
            .unit_price_minor = line.unit_price_minor,
            .tax_bps = line.tax_bps,
            .notes = line.notes,
        };
        index += 1;
    }
    model.active_lines = list[0..index];
}

/// The waiter picked a table. If the table already has an open order,
/// the waiter joins it; if it is free, a new order is opened for it.
fn selectTable(model: *Model, fx: *Effects, table_id: i64) void {
    // The order is being opened; a second tap would open a second one
    // for the same table.
    if (model.pending_order_id != 0) return;
    const table = findTable(model, table_id) orelse return;
    model.waiter_buf.reset();
    model.active_table_id = table.id;
    model.active_table_name_field = model.waiter_buf.dupe(table.name) orelse "";

    // Does the table already have an open order?
    for (model.orders) |order| {
        if (order.dining_table_id != table.id) continue;
        switch (order.status) {
            .pending, .preparing, .ready, .served => {
                model.active_order_id = order.id;
                go(model, .waiter_menu);
                repos.loadOrderLines(model, fx);
                return;
            },
            .completed, .voided, .held => {},
        }
    }

    // A free table: open an order for it. The order number is a
    // sequence, and the database assigns it.
    const order_id = nextOrderId(model, fx.wallMs());
    model.pending_order_id = order_id;
    repos.openOrderForTable(model, fx, repos.key_open_order, table.id, model.employee_id, order_id);
}

/// Add a product to the open order the waiter is serving.
fn addToOrder(model: *Model, fx: *Effects, product_id: i64) void {
    if (model.active_order_id == 0) {
        model.error_text = "Pick a table first";
        return;
    }
    // The table can be paid for while the waiter is still holding the
    // menu. The board carries the closed status; a plate must not land
    // on a bill the customer has already settled.
    const order = findOrder(model, model.active_order_id) orelse {
        model.error_text = "That table's order is no longer open";
        return;
    };
    if (order.status == .completed or order.status == .voided) {
        model.error_text = "That table has been paid - start a new order";
        return;
    }
    // One plate at a time. The op carries the whole ticket, so the
    // second plate has to see the first one in the list.
    if (model.add_line_pending) {
        model.error_text = "The last item is still being added";
        return;
    }
    const product = findProduct(model, product_id) orelse return;
    model.add_line_pending = true;
    repos.addOrderLine(
        model,
        fx,
        repos.key_add_line,
        model.active_order_id,
        product.id,
        product.name,
        product.price_minor,
        fx.wallMs(),
    );
}

/// Open the product form: an existing product, or a new one.
fn openProductForm(model: *Model, id: i64) void {
    model.form_product_id = id;
    model.form_product_name_buf.set("");
    model.form_product_price_buf.set("");
    model.form_product_category_id = 0;
    model.form_product_food_id = 0;
    if (id != 0) {
        for (model.products) |product| {
            if (product.id != id) continue;
            model.form_product_name_buf.set(product.name);
            var price_buffer: [24]u8 = undefined;
            model.form_product_price_buf.set(priceAsTyped(&price_buffer, product.price_minor, model.currency_decimals));
            model.form_product_category_id = product.category_id;
            model.form_product_food_id = @intFromEnum(product.food_type);
            break;
        }
    }
    go(model, .product_form);
}

/// Open the employee form: an existing employee, or a new one.
fn openEmployeeForm(model: *Model, id: i64) void {
    model.form_employee_id = id;
    model.form_employee_name_buf.set("");
    model.form_employee_role_id = 0;
    if (id != 0) {
        for (model.employees) |employee| {
            if (employee.id != id) continue;
            model.form_employee_name_buf.set(employee.name);
            model.form_employee_role_id = employee.role;
            break;
        }
    }
    go(model, .employee_form);
}

/// Open the category form: an existing category, or a new one.
fn openCategoryForm(model: *Model, id: i64) void {
    model.form_category_id = id;
    model.form_category_name_buf.set("");
    if (id != 0) {
        for (model.categories) |category| {
            if (category.id != id) continue;
            model.form_category_name_buf.set(category.name);
            break;
        }
    }
    go(model, .category_form);
}

/// Save the category the form is editing.
fn saveCategory(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_category_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The category needs a name";
        return;
    }
    const id = if (model.form_category_id != 0) model.form_category_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveCategory(fx, repos.key_save_category, id, name, fx.wallMs());
}

/// Open the discount form: an existing discount, or a new one.
fn openDiscountForm(model: *Model, id: i64) void {
    model.form_discount_id = id;
    model.form_discount_name_buf.set("");
    model.form_discount_percent_buf.set("");
    model.form_discount_amount_buf.set("");
    if (id != 0) {
        for (model.discounts_list) |discount| {
            if (discount.id != id) continue;
            model.form_discount_name_buf.set(discount.name);
            var text_buffer: [24]u8 = undefined;
            model.form_discount_percent_buf.set(rateAsTyped(&text_buffer, discount.percent_bps));
            model.form_discount_amount_buf.set(priceAsTyped(&text_buffer, discount.amount_minor, model.currency_decimals));
            break;
        }
    }
    go(model, .discount_form);
}

/// Open the tax slab form: an existing slab, or a new one.
fn openTaxSlabForm(model: *Model, id: i64) void {
    model.form_tax_slab_id = id;
    model.form_tax_slab_name_buf.set("");
    model.form_tax_slab_rate_buf.set("");
    model.form_tax_slab_inclusive = false;
    if (id != 0) {
        for (model.tax_slabs_list) |slab| {
            if (slab.id != id) continue;
            model.form_tax_slab_name_buf.set(slab.name);
            var rate_buffer: [24]u8 = undefined;
            model.form_tax_slab_rate_buf.set(rateAsTyped(&rate_buffer, slab.rate_bps));
            model.form_tax_slab_inclusive = slab.inclusive;
            break;
        }
    }
    go(model, .tax_slab_form);
}

/// A rate in basis points, as the form shows it: the percentage, with
/// no decimals the owner did not type. The caller owns the buffer: a
/// slice of a local would point at this function's dead frame.
fn rateAsTyped(buffer: []u8, rate_bps: i64) []const u8 {
    if (@mod(rate_bps, 100) == 0) {
        const written = std.fmt.bufPrint(buffer, "{d}", .{@divTrunc(rate_bps, 100)}) catch return "";
        return written;
    }
    const written = std.fmt.bufPrint(buffer, "{d}.{d:0>2}", .{ @divTrunc(rate_bps, 100), @mod(rate_bps, 100) }) catch return "";
    return written;
}

/// A price in minor units, as the form shows it: the amount in the
/// company's currency, with its own number of decimals and no symbol.
/// The caller owns the buffer for the same reason as `rateAsTyped`.
fn priceAsTyped(buffer: []u8, minor: i64, decimals: i64) []const u8 {
    if (decimals <= 0) {
        return std.fmt.bufPrint(buffer, "{d}", .{minor}) catch return "";
    }
    if (decimals > 9) return "";
    const divisor = tenTo(decimals);
    const whole = @divTrunc(minor, divisor);
    const frac = @mod(minor, divisor);
    const whole_text = std.fmt.bufPrint(buffer, "{d}", .{whole}) catch return "";
    var written = whole_text.len;
    if (written + 1 + @as(usize, @intCast(decimals)) > buffer.len) return "";
    buffer[written] = '.';
    written += 1;
    const padded = writePadded(buffer[written..], frac, @intCast(decimals)) orelse return "";
    return buffer[0 .. written + padded];
}

/// Write `value` right-aligned in a field of `width` zeroes. The form
/// needs it because a currency's decimals are not a compile-time two.
fn writePadded(buffer: []u8, value: i64, width: usize) ?usize {
    var digits_buffer: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buffer, "{d}", .{value}) catch return null;
    if (digits.len > width or width > buffer.len) return null;
    const padding = width - digits.len;
    @memset(buffer[0..padding], '0');
    @memcpy(buffer[padding..][0..digits.len], digits);
    return width;
}

/// Ten to the power of a small exponent: the divisor a currency's
/// decimals mean.
fn tenTo(exponent: i64) i64 {
    var value: i64 = 1;
    var index: i64 = 0;
    while (index < exponent) : (index += 1) value *= 10;
    return value;
}

/// Save the discount the form is editing.
///
/// A discount is a share of the bill, an amount off it, or both. The
/// cashier's rule is the one the model already uses: a percentage wins,
/// and an amount is what is left when there is no percentage.
fn saveDiscount(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_discount_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The discount needs a name";
        return;
    }
    const percent = if (model.form_discount_percent_buf.text().len == 0)
        0
    else
        parsePrice(model.form_discount_percent_buf.text()) orelse {
            model.error_text = "The percent must be a number - ten for ten percent";
            return;
        };
    const amount = if (model.form_discount_amount_buf.text().len == 0)
        0
    else
        parseAmount(model.form_discount_amount_buf.text(), model.currency_decimal_count()) orelse {
            model.error_text = "The amount must be a number this currency can say";
            return;
        };
    if (percent > 10000) {
        model.error_text = "A discount cannot be more than a hundred percent";
        return;
    }
    if (percent == 0 and amount == 0) {
        model.error_text = "A discount has to take something off";
        return;
    }
    const id = if (model.form_discount_id != 0) model.form_discount_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveDiscount(fx, repos.key_save_discount, id, name, percent, amount, fx.wallMs());
}

/// Save the tax slab the form is editing.
///
/// The rate is a percentage, and the percentage's hundredths are the
/// rate's basis points: five percent is five hundred, and twelve and
/// three quarters is one thousand two hundred and seventy five.
fn saveTaxSlab(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_tax_slab_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The tax slab needs a name";
        return;
    }
    const rate = parsePrice(model.form_tax_slab_rate_buf.text()) orelse {
        model.error_text = "The rate must be a number - five for five percent";
        return;
    };
    if (rate > 10000) {
        model.error_text = "A rate cannot be more than a hundred percent";
        return;
    }
    const id = if (model.form_tax_slab_id != 0) model.form_tax_slab_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveTaxSlab(fx, repos.key_save_tax_slab, id, name, rate, model.form_tax_slab_inclusive);
}

/// Save the product the form is editing.
fn saveProduct(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_product_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The product needs a name";
        return;
    }
    const price = parseAmount(model.form_product_price_buf.text(), model.currency_decimal_count()) orelse {
        model.error_text = "The price is not a number this currency can say";
        return;
    };
    if (model.form_product_category_id == 0) {
        model.error_text = "Pick a category";
        return;
    }
    const id = if (model.form_product_id != 0) model.form_product_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveProduct(
        fx,
        repos.key_save_product,
        id,
        model.form_product_category_id,
        name,
        price,
        model.form_product_food_id,
        fx.wallMs(),
    );
}

/// Save the employee the form is editing.
fn saveEmployee(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_employee_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The employee needs a name";
        return;
    }
    const id = if (model.form_employee_id != 0) model.form_employee_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveEmployee(fx, repos.key_save_employee, id, name, model.form_employee_role_id, fx.wallMs());
}

/// The two readers a typed figure goes through. Money takes the
/// currency's decimals, so the price, the discount and the cash tender
/// cannot disagree about what an amount means; a rate keeps the hundred
/// that belongs to a percent and takes the fixed two decimals instead.
const parsePrice = model_mod.parsePrice;
const parseAmount = model_mod.parseAmount;

/// Save the company. The name is the one field that must not be empty:
/// it is on every receipt.
fn saveCompany(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The restaurant needs a name";
        return;
    }
    // The colour is the one field that may be left empty, because empty
    // is the answer "the restaurant has no colour of its own". Anything
    // else has to be a colour, and a half-typed hash is not one.
    const brand = std.mem.trim(u8, model.form_brand_buf.text(), " ");
    if (brand.len != 0 and model_mod.parseBrand(brand) == null) {
        model.error_text = "The brand colour is a hash and six digits, like #1F7A8C";
        return;
    }
    model.busy = true;
    model.error_text = "";
    repos.updateCompany(
        fx,
        repos.key_save_company,
        name,
        std.mem.trim(u8, model.form_address_buf.text(), " "),
        std.mem.trim(u8, model.form_phone_buf.text(), " "),
        std.mem.trim(u8, model.form_tax_buf.text(), " "),
        brand,
    );
}

/// Rotate the device's pairing token.
///
/// The typed value becomes the truth the moment it is saved: the thread
/// is handed it before the write is asked for, because a peer that has
/// already been told the new token should not be refused while the
/// database catches up. The write is an UPDATE, so the first rotation
/// replaces whatever boot seeded.
fn savePairing(model: *Model, fx: *Effects) void {
    const token = std.mem.trim(u8, model.pairing_entry.text(), " ");
    if (token.len == 0) {
        model.error_text = "A token of spaces pairs nobody";
        return;
    }
    const copied = model.pairing_buf[0..];
    @memcpy(copied[0..token.len], token);
    model.pairing_len = token.len;
    net_bridge.sharePairing(model);
    model.pairing_entry.clear();
    model.error_text = "";
    repos.setPairing(fx, model.pairing(), fx.wallMs());
}

/// Take the payment for the order that was just placed and close it.
fn takePayment(model: *Model, fx: *Effects) void {
    if (model.last_order_id == 0) {
        model.payment_error = "There is no order to pay for";
        return;
    }
    // One payment at a time: a second tap would take the money twice.
    if (model.payment_pending) {
        model.payment_error = "The payment is still being taken";
        return;
    }
    const order = findOrder(model, model.last_order_id) orelse {
        model.payment_error = "That order is no longer on the board";
        return;
    };
    if (order.paid or order.status == .completed) {
        model.payment_error = "This order is already paid";
        return;
    }
    if (order.status == .voided) {
        model.payment_error = "A voided order cannot be paid";
        return;
    }
    const mode = std.enums.fromInt(domain.PaymentMode, model.payment_mode_field) orelse domain.PaymentMode.cash;
    // A sale on account is a receivable: it needs a customer and a due
    // date, and it is not money the drawer received. Until there is a
    // book to put it in, the till says so instead of writing a cash
    // payment that never happened.
    if (mode == .credit) {
        model.payment_error = "On account is not available - take the payment now";
        return;
    }
    // Cash: what the customer handed over has to cover the bill. An
    // empty field means the exact amount - the common case - and the
    // change is what the confirmation screen shows. The payment row is
    // still the bill, not the tender: the change never was revenue.
    if (mode == .cash) {
        const tendered_text = std.mem.trim(u8, model.cash_tendered_buf.text(), " ");
        if (tendered_text.len > 0) {
            const tendered = parseAmount(tendered_text, model.currency_decimal_count()) orelse {
                model.payment_error = "The cash received is not an amount this currency can say";
                return;
            };
            if (tendered < order.total_minor) {
                model.payment_error = "The cash received is less than the total";
                return;
            }
        }
    }
    model.busy = true;
    model.payment_pending = true;
    model.payment_error = "";
    repos.takePayment(
        model,
        fx,
        repos.key_payment,
        order.id,
        mode,
        order.total_minor,
        fx.wallMs(),
    );
}

/// Set up the restaurant: the company, the first operator, and the
/// starter menu and floor. One transaction, in `repos.setupCompany`.
fn submitSetup(model: *Model, fx: *Effects) void {
    // One writer for the restaurant: the admin app. A service or kiosk
    // gets its rows over the wire, and a second company row would make
    // "which menu is the menu?" unanswerable.
    if (model_mod.app_kind != .admin) {
        model.setup_error = "The restaurant is set up on the admin device";
        return;
    }
    const name = std.mem.trim(u8, model.setup_company_name.text(), " ");
    const admin = std.mem.trim(u8, model.setup_admin_name.text(), " ");
    const secret = model.setup_credential.text();
    const kind = model.setup_credential_kind;

    if (name.len == 0) {
        model.setup_error = "Give the restaurant a name";
        return;
    }
    if (admin.len == 0) {
        model.setup_error = "Give the operator a name";
        return;
    }
    if (secret.len == 0) {
        model.setup_error = if (kind == .pin) "Choose a PIN" else "Choose a password";
        return;
    }
    if (!std.mem.eql(u8, secret, model.setup_credential2.text())) {
        model.setup_error = if (kind == .pin) "The two PINs do not match" else "The two passwords do not match";
        return;
    }

    // The secret is hashed with the installation salt and the first
    // employee's id, exactly as it is at every other sign-in. Whatever
    // kind it is, the plaintext never reaches the disk.
    var hash: [auth.hash_length]u8 = undefined;
    const hashed = auth.hashCredential(model.salt(), repos.first_employee_id, secret, &hash) orelse {
        model.setup_error = "Could not hash the credential - try again";
        return;
    };

    const code = std.mem.trim(u8, model.setup_currency_code.text(), " ");
    const symbol = std.mem.trim(u8, model.setup_currency_symbol.text(), " ");

    model.busy = true;
    model.setup_error = "";
    const currency = if (code.len == 0) "USD" else code;
    repos.setupCompany(
        fx,
        repos.key_setup,
        name,
        currency,
        if (symbol.len == 0) "$" else symbol,
        admin,
        hashed,
        @intFromEnum(kind),
        model.salt(),
        model_mod.decimalsForCurrency(currency),
        std.mem.trim(u8, model.wizard_address_buf.text(), " "),
        std.mem.trim(u8, model.wizard_phone_buf.text(), " "),
        std.mem.trim(u8, model.wizard_tax_buf.text(), " "),
        fx.wallMs(),
    );
}

/// A fresh installation keeps the salt made at boot and writes it once.
///
/// The salt is NOT marked as confirmed here: the write has not happened
/// yet. A failed write that still cleared the flag would leave the app
/// hashing credentials against a salt that is not in the database - the
/// operator signs in, the next boot makes a different salt, and nobody
/// can ever sign in again. The write coming back moves the state to
/// `.verifying`; only the read-back in `config_loaded` confirms the salt
/// the database actually holds.
fn createSalt(model: *Model, fx: *Effects) void {
    repos.saveSalt(fx, repos.key_save_salt, model.salt(), fx.wallMs());
}

/// Wear a palette, and keep the choice.
///
/// The look belongs to the device, not to the restaurant, so it is
/// stored in `app_config` beside the salt and read back at boot. Marking
/// the choice is what makes a read that lands late harmless: the tap the
/// operator made is the truth, and the stored value only fills in a
/// device nobody has set yet.
fn chooseTheme(model: *Model, fx: *Effects, palette: model_mod.Palette, contrast: bool) void {
    model.theme_palette = palette;
    model.theme_contrast_high = contrast;
    model.theme_chosen = true;
    repos.saveTheme(fx, @intFromEnum(palette), contrast, fx.wallMs());
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    // A read that has come back is no longer on its way, and a read
    // that failed is something the operator can try again. This is
    // the ONE place that knows it, so every read behaves the same way
    // whether it is the menu or the tables in the database.
    if (msg.readOutcome()) |ok| {
        model.reading = false;
        if (!ok) {
            model.read_failed = true;
            model.failed_screen = model.screen();
            if (model.error_text.len == 0) {
                model.error_text = "The data could not be read - try again";
            }
        }
    }

    switch (msg) {
        // ----------------------------------------------------------- the wire

        .net => |event| net_bridge.onChannel(model, fx, event),
        .peer => |response| net_bridge.onResponse(model, fx, response),
        .snapshot => |response| net_bridge.onSnapshotResponse(model, fx, response),
        .net_event => |line| net_bridge.onEventLine(model, fx, line),
        .event_done => |response| net_bridge.onEventDone(model, response),
        .sync_ops_loaded => |result| net_bridge.onOpsLoaded(model, result),
        .sync_snapshot_loaded => |result| net_bridge.onSnapshotLoaded(model, result),
        .sync_compacted => |result| repos.onSyncCompacted(model, result),
        .sync_applied => |result| {
            // The cursor has already moved; a failed apply is a gap the
            // operator can see, not a loop that retries forever.
            if (result.outcome != .ok) {
                model.sync_rejected += 1;
            } else {
                // The op is committed. Wake the other peers' streams
                // and re-read the board now, so the event stream's
                // promise - the ticket appears without waiting for the
                // next poll - reaches the screen and not just the
                // database.
                net_bridge.notify();
                repos.loadOrders(model, fx);
                repos.maybeCompact(model, fx);
            }
        },
        .reference => |response| net_bridge.onReferenceResponse(model, fx, response),
        .reference_bumped => |result| {
            // The counter moved. Rebuild the document the peer asks
            // for; serving the old one under the new version would be
            // a lie the receiver could not detect.
            if (result.outcome == .ok) repos.loadReferenceSnapshot(model, fx);
        },
        .reference_loaded => |result| {
            if (result.outcome != .ok or result.kind != .page) return;
            var reader = page.Reader.init(result.bytes);
            var values: [page.max_columns]page.Value = undefined;
            if (!reader.readHeader()) return;
            if (!reader.nextRow(&values)) return;
            const version = reader.intOf(&values, "version", 0);
            const json = reader.textOf(&values, "snapshot");
            model.reference_snapshot_buf.reset();
            const copied = model.reference_snapshot_buf.dupe(json) orelse return;
            model.reference_snapshot_len = copied.len;
            model.reference_version = if (version > 0) @as(u64, @intCast(version)) else 1;
        },
        .reference_version_loaded => |result| {
            if (result.outcome != .ok or result.kind != .page) return;
            var reader = page.Reader.init(result.bytes);
            var values: [page.max_columns]page.Value = undefined;
            if (!reader.readHeader()) return;
            if (!reader.nextRow(&values)) return;
            const version = reader.intOf(&values, "version", 0);
            if (version > 0) model.reference_version = @intCast(version);
        },
        .reference_applied => |result| {
            if (result.outcome != .ok) {
                // The version did not move, so the next pull asks for
                // the same document again.
                model.reference_applying = 0;
                model.sync_rejected += 1;
                return;
            }
            if (model.reference_applying > model.reference_version) {
                model.reference_version = model.reference_applying;
            }
            model.reference_applying = 0;
            // The catalogue, the people, the tables and the salt all
            // changed; reload what the screens read.
            repos.loadConfig(model, fx);
            repos.loadCompany(model, fx);
            repos.loadCategories(model, fx);
            repos.loadTaxSlabs(model, fx);
            repos.loadProducts(model, fx);
            repos.loadEmployees(model, fx);
            repos.loadTableCategories(model, fx);
            repos.loadTables(model, fx);
            repos.loadStations(model, fx);
        },

        // -------------------------------------------------------- session

        .pick_role => |index| {
            const role = std.enums.fromInt(Role, index) orelse return;
            // A binary runs its own roles only. The kiosk may choose
            // between its two boards; admin and service may not be moved
            // to a role the build does not carry.
            if (!model_mod.allows_role(role)) return;
            // Choosing a role is a session boundary. The previous
            // operator's cart, filters and history end here.
            resetSession(model, if (role.needs_sign_in()) .login else rbac.home(role));
            model.role = role;
            model.role_chosen = true;
            if (role.needs_sign_in()) return;
            // Kiosk roles are signed in by device.
            model.signed_in = true;
            repos.loadAll(model, fx);
            // The kitchen and the customer display watch the orders
            // instead of waiting for a refresh: a live query re-runs
            // itself when the `orders` table changes.
            if (role == .kds or role == .display) {
                repos.watchOpenOrders(fx);
                // A live query only sees the writes THIS connection
                // made. The kitchen is usually another device, so the
                // board also re-reads on a timer: that is what makes a
                // sale on the cashier's machine appear on the kitchen's
                // screen.
                fx.startTimer(.{
                    .key = repos.key_board_refresh,
                    .interval_ms = 2000,
                    .mode = .repeating,
                    .on_fire = Effects.timerMsg(.refresh_orders),
                });
            }
        },

        .credential_edit => |event| {
            if (model.login_locked()) return;
            applySecretEdit(&model.credential, event);
        },

        .credential_digit => |digit| {
            // The pad: one key, one digit. A PIN is tapped rather than
            // typed because a till has a screen in front of a queue, and
            // a keyboard would be a keyboard.
            if (model.login_locked()) return;
            if (model.credential.text().len >= auth.max_pin_len) return;
            var next: [auth.max_secret_len]u8 = undefined;
            const held = model.credential.text();
            @memcpy(next[0..held.len], held);
            next[held.len] = '0' + @as(u8, @intCast(digit));
            model.credential.set(next[0 .. held.len + 1]);
        },

        .credential_clear => {
            if (model.login_locked()) return;
            model.credential.clear();
        },

        .credential_back => {
            if (model.login_locked()) return;
            const held = model.credential.text();
            if (held.len == 0) return;
            model.credential.set(held[0 .. held.len - 1]);
        },

        .toggle_reveal => model.credential_revealed = !model.credential_revealed,

        .pick_employee => |id| {
            // The person the picker chose. Their role is the mode they
            // work in, so the picker does not ask twice: the operator
            // says who they are, not which mode they are in.
            const employee = findEmployee(model, id) orelse {
                model.error_text = "That employee is not on the list";
                return;
            };
            const role = rbac.role_for_employee(employee.role) orelse {
                model.error_text = "That employee has no role this app knows";
                return;
            };
            // The app is one role. A waiter's row must not open the
            // back office because the device happens to be an admin
            // till: the person's role and the binary's role have to
            // agree, which is the same rule the credential check applies.
            if (!model_mod.allows_role(role)) {
                model.error_text = "That person does not work on this device";
                return;
            }
            resetSession(model, .login);
            model.role = role;
            model.role_chosen = true;
            // How they prove it is theirs, and the surface is built from
            // that: a pad for a PIN, a field for a password.
            choose_sign_in(model, employee);
        },

        .submit_login => {
            // The till stops guessing. A PIN is short, and a short PIN
            // is found by trying every one of them; the till is where
            // that trying happens, so the till is where it stops.
            if (model.login_locked()) {
                model.login_error = "Too many wrong tries - try again in a moment";
                return;
            }
            if (model.credential.text().len == 0) {
                model.login_error = missingSecret(model.credential_kind);
                return;
            }
            // Nobody is signing in without a person: the picker chose
            // who, and the secret says they are that person.
            if (model.sign_in_employee_id == 0) {
                model.login_error = "Choose who you are first";
                return;
            }
            fx.dbQuery(.{
                .key = repos.key_login,
                // The employee the picker chose. The hash is not
                // computed here: the row's own hash is verified
                // against the secret, and that is ONE slow hash, not
                // one per employee on the staff list.
                .sql = repos.login_sql,
                .params = &.{.{ .integer = model.sign_in_employee_id }},
                .on_result = Effects.dbMsg(.login_checked),
            });
        },

        .login_checked => |result| {
            if (result.outcome != .ok) {
                noteLoginFailure(model);
                model.login_error = "Sign-in failed - try again";
                model.credential.clear();
                return;
            }
            // A query answers with a page and then a terminal message
            // that says it is finished. The terminal is not a wrong
            // credential: counting it would make the till lock after
            // fewer real guesses than it says it will, and it would
            // overwrite the instruction the screen just gave.
            if (result.kind != .page) return;
            var reader = page.Reader.init(result.bytes);
            var values: [page.max_columns]page.Value = undefined;
            if (!reader.readHeader() or !reader.nextRow(&values)) {
                noteLoginFailure(model);
                model.login_error = wrongSecret(model.credential_kind);
                model.credential.clear();
                return;
            }
            // The row that came back has to be the employee the
            // picker chose, and that employee has to work in THIS
            // mode. The query already asks for the first; this is the
            // check that says so, and it is what keeps the permission
            // matrix from being decoration.
            const employee_id = reader.intOf(&values, "id", 0);
            if (employee_id != model.sign_in_employee_id) {
                model.login_error = wrongSecret(model.credential_kind);
                model.credential.clear();
                return;
            }
            const stored_role = reader.intOf(&values, "role", -1);
            if (stored_role != @intFromEnum(rbac.employee_role(model.role))) {
                model.login_error = wrongSecret(model.credential_kind);
                model.credential.clear();
                return;
            }
            // The row says how this person signs in, and the row is the
            // truth. A list read before a change on another device can
            // have offered the wrong surface; the secret typed into it
            // is not held against them, and the screen becomes the other
            // one for the next try.
            const stored_kind = domain.CredentialKind.fromInt(reader.intOf(&values, "auth_kind", 0)) orelse .pin;
            if (stored_kind != model.credential_kind) {
                model.credential_kind = stored_kind;
                model.credential.clear();
                model.login_error = switch (stored_kind) {
                    .pin => "This person signs in with a PIN - tap it",
                    .password => "This person signs in with a password - type it",
                };
                return;
            }
            // The row's hash is the one the secret has to match. A
            // bcrypt hash carries its own salt, so verifying it needs
            // nothing but the secret - which is why a second device can
            // check a credential it was never given the salt for.
            const stored = reader.textOf(&values, "pin_hash");
            if (stored.len == 0) {
                // An employee who has never been given a secret cannot
                // sign in. Saying so is better than a wrong one: the
                // secret is not wrong, it was never set.
                model.login_error = noSecret(model.credential_kind);
                model.credential.clear();
                return;
            }
            // A hash from before bcrypt is salted with the
            // installation, so verifying it needs the installation
            // salt - and the salt has to be the salt the DATABASE
            // holds, or the hash cannot match. Until the database has
            // confirmed it, there is nothing to check with, so the
            // sign-in waits rather than guessing.
            if (auth.isLegacy(stored) and (model.salt().len == 0 or model.salt_state != .confirmed)) {
                model.login_error = "Still starting up - try again in a moment";
                model.credential.clear();
                return;
            }
            if (!auth.verifyCredential(model.salt(), model.credential.text(), stored)) {
                noteLoginFailure(model);
                model.login_error = wrongSecret(model.credential_kind);
                model.credential.clear();
                return;
            }
            // The modern hash for a row that still holds an old digest.
            // It is made BEFORE the session reset, because the reset
            // clears the secret the hash is made from.
            const legacy = auth.isLegacy(stored);
            if (legacy) {
                const hashed = auth.hashCredential(model.salt(), model.sign_in_employee_id, model.credential.text(), &model.login_hash) orelse {
                    model.login_error = "Could not check the credential - try again";
                    model.credential.clear();
                    return;
                };
                model.login_hash_len = hashed.len;
            }
            // The session begins now. Reset before taking the name:
            // the reset clears the operator buffer the name lives in.
            const employee_name = reader.textOf(&values, "name");
            resetSession(model, rbac.home(model.role));
            model.employee_id = employee_id;
            model.employee_name = model.operator_buf.dupe(employee_name) orelse "";
            model.signed_in = true;
            model.role_chosen = true;
            // The person the picker chose is now the person who is
            // signed in, so the pending choice ends here. Leaving it
            // would keep a second answer to "who is at this till"
            // around for the whole session, and a secret typed at a
            // stale gate is checked against the person it names.
            model.sign_in_employee_id = 0;
            model.sign_in_employee_name_len = 0;
            // The counter of wrong secrets starts again: the cashier is
            // in, and the till is not holding a grudge.
            model.login_failures = 0;
            model.login_locked_until = 0;
            repos.loadAll(model, fx);
            // A hash from before bcrypt is rewritten in the modern
            // form, so the next sign-in of this employee is a slow
            // one and the old digest stops being worth anything. The
            // modern hash carries its own salt, so it needs nothing
            // but this employee's row to be checked on another device.
            if (legacy) {
                repos.savePinHash(fx, repos.key_save_pin_hash, model.employee_id, model.login_hash[0..model.login_hash_len]);
            }
        },

        .pick_role_again => {
            resetSession(model, .role_picker);
            model.role_chosen = false;
        },

        .sign_out => {
            // A role a person signs in to goes back to that person's
            // sign-in gate. A kiosk role has no credential, so it goes
            // back to the picker that chooses the device's mode - and
            // so does a person whose row has gone away, because a gate
            // for nobody is a gate a secret gets typed at no one.
            const person = findEmployee(model, model.employee_id);
            const gate: Screen = if (model.role.needs_sign_in() and person != null) .login else .role_picker;
            // The row is read before the reset, because the reset is
            // what clears who was signed in.
            resetSession(model, gate);
            if (gate == .login) choose_sign_in(model, person.?);
            model.role_chosen = gate == .login;
        },

        // ------------------------------------------------------- first run

        .wizard_next => {
            // The company first, then the owner. The step that is NOT
            // on the screen is not asked for.
            const name = std.mem.trim(u8, model.setup_company_name.text(), " ");
            if (name.len == 0) {
                model.error_text = "Give the restaurant a name";
                return;
            }
            model.error_text = "";
            go(model, .wizard);
        },

        .wizard_back => {
            model.error_text = "";
            go(model, .create_company);
        },

        .wizard_quick_setup => {
            // The quick setup asks for less and takes less. It is the
            // same restaurant, written the same way.
            go(model, .setup);
        },

        .wizard_address_edit => |event| model.wizard_address_buf.apply(event),

        .wizard_phone_edit => |event| model.wizard_phone_buf.apply(event),

        .wizard_tax_edit => |event| model.wizard_tax_buf.apply(event),

        .setup_company_edit => |event| model.setup_company_name.apply(event),

        .setup_admin_edit => |event| model.setup_admin_name.apply(event),

        .setup_credential_edit => |event| applySecretEdit(&model.setup_credential, event),

        .setup_credential2_edit => |event| applySecretEdit(&model.setup_credential2, event),

        .setup_credential_kind => |id| {
            model.setup_credential_kind = domain.CredentialKind.fromInt(id) orelse .pin;
        },

        .setup_currency_edit => |event| model.setup_currency_code.apply(event),

        .setup_symbol_edit => |event| model.setup_currency_symbol.apply(event),

        .setup_submit => submitSetup(model, fx),

        .setup_created => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                // A failed setup is still a session boundary: nothing
                // from a partial first run may leak into the retry.
                resetSession(model, .setup);
                model.setup_error = switch (result.outcome) {
                    .constraint => "That setup breaks a data rule - try different names",
                    .busy => "The database is busy - try again",
                    else => "Could not set up the restaurant",
                };
                return;
            }
            // The restaurant exists: the operator is signed in, and the
            // app becomes a POS.
            resetSession(model, .admin_dashboard);
            model.needs_setup = false;
            model.signed_in = true;
            model.employee_id = 1;
            model.employee_name = model.operator_buf.dupe(model.setup_admin_name.text()) orelse "";
            model.role_chosen = true;
            model.role = .admin;
            // The setup wrote the salt in the same transaction as the
            // operator's PIN hash, so the salt in the model is now the
            // salt in the database. A sign-in may use it.
            model.salt_state = .confirmed;
            repos.loadAll(model, fx);
            if (model_mod.app_kind == .admin) {
                // The first document includes the salt and the owner's
                // PIN hash, so a peer can sign in with them.
                repos.loadReferenceSnapshot(model, fx);
            } else {
                repos.loadReferenceVersion(model, fx);
            }
        },

        // ----------------------------------------------------- navigation

        .open_screen => |index| {
            const screen = std.enums.fromInt(Screen, index) orelse return;
            // The company form starts from what is stored: opening the
            // settings shows the saved details, not an empty form. It
            // is seeded HERE, when the screen is opened - seeding it on
            // every load would wipe what the operator is typing.
            if (screen == .settings_company and model.company_id != 0) {
                model.form_name_buf.set(model.company_name_field);
                model.form_address_buf.set(model.company_address_field);
                model.form_phone_buf.set(model.company_phone_field);
                model.form_tax_buf.set(model.company_tax_field);
                model.form_brand_buf.set(model.company_brand_field);
            }
            go(model, screen);
            // The screen loads what it shows: the effects channel has
            // sixteen slots, and loading everything at once fills them
            // and the late queries are refused.
            repos.loadForScreen(model, fx, screen);
        },

        .open_section => |ordinal| {
            // The rail row carries the SECTION ORDINAL, not its position
            // in the list: the two differ the moment a role's rail is
            // not the full set (the waiter's rail has one row, and its
            // ordinal is 7).
            const section = std.enums.fromInt(nav.NavSection, ordinal) orelse return;
            const section_id = section.index();
            var known = false;
            for (rbac.nav_sections(model.role)) |row| {
                if (row.id == section_id) known = true;
            }
            if (!known) return;
            go(model, rbac.section_screen(section));
        },

        .go_back => {
            if (model.stack.pop()) |screen| {
                model.screen_index = screen.index();
                model.nav_section = sectionIndex(screen);
            }
        },

        .rail_resized => |fraction| model.rail_split = fraction,

        .menu_resized => |fraction| model.menu_split = fraction,

        .open_pos => go(model, .pos),

        .open_pos_cart => go(model, .pos_cart),

        .open_orders => go(model, .orders),

        .open_payments => {
            go(model, .payments);
            repos.loadPayments(model, fx);
        },

        .open_reports => {
            go(model, .reports);
            repos.loadReport(model, fx, model.report_day_start_ms());
        },

        .open_dashboard => go(model, .admin_dashboard),

        .deactivate_employee => |id| {
            if (id == 0) return;
            // The last admin cannot be deactivated: a restaurant with
            // no admin cannot open the back office, and the owner
            // would have no way back in.
            if (model.is_last_admin(id)) {
                model.error_text = "The last admin cannot be removed - make someone else an admin first";
                return;
            }
            model.busy = true;
            model.error_text = "";
            repos.deactivateEmployee(fx, repos.key_deactivate_employee, id);
        },

        .open_customers => {
            go(model, .customers);
            repos.loadCustomers(model, fx);
        },

        .new_customer => {
            model.form_customer_id = 0;
            model.form_customer_name_buf.set("");
            model.form_customer_phone_buf.set("");
            model.form_customer_email_buf.set("");
            model.form_customer_address_buf.set("");
            go(model, .customer_form);
        },

        .edit_customer => |id| {
            model.form_customer_id = id;
            model.form_customer_name_buf.set("");
            model.form_customer_phone_buf.set("");
            model.form_customer_email_buf.set("");
            model.form_customer_address_buf.set("");
            for (model.customers) |customer| {
                if (customer.id != id) continue;
                model.form_customer_name_buf.set(customer.name);
                model.form_customer_phone_buf.set(customer.phone);
                model.form_customer_email_buf.set(customer.email);
                break;
            }
            go(model, .customer_form);
        },

        .form_customer_name_edit => |event| model.form_customer_name_buf.apply(event),

        .form_customer_phone_edit => |event| model.form_customer_phone_buf.apply(event),

        .form_customer_email_edit => |event| model.form_customer_email_buf.apply(event),

        .form_customer_address_edit => |event| model.form_customer_address_buf.apply(event),

        .save_customer => {
            const name = std.mem.trim(u8, model.form_customer_name_buf.text(), " ");
            if (name.len == 0) {
                model.error_text = "The customer needs a name";
                return;
            }
            const phone = std.mem.trim(u8, model.form_customer_phone_buf.text(), " ");
            const email = std.mem.trim(u8, model.form_customer_email_buf.text(), " ");
            const address = std.mem.trim(u8, model.form_customer_address_buf.text(), " ");
            const id = if (model.form_customer_id != 0) model.form_customer_id else fx.wallMs();
            model.busy = true;
            model.error_text = "";
            repos.saveCustomer(fx, repos.key_save_customer, id, name, phone, email, address, fx.wallMs());
        },

        .customer_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "The customer could not be saved - try again";
                return;
            }
            model.error_text = "";
            repos.loadCustomers(model, fx);
            go(model, .customers);
        },

        .open_table_categories => {
            go(model, .table_categories);
            repos.loadTableCategories(model, fx);
        },

        .open_landing => go(model, .landing),

        .open_floor_plan => {
            go(model, .floor_plan);
            repos.loadTables(model, fx);
        },

        .new_table_category => {
            model.form_table_category_id = 0;
            model.form_table_category_name_buf.set("");
            go(model, .table_category_form);
        },

        .edit_table_category => |id| {
            model.form_table_category_id = id;
            model.form_table_category_name_buf.set("");
            for (model.table_categories_list) |category| {
                if (category.id != id) continue;
                model.form_table_category_name_buf.set(category.name);
                break;
            }
            go(model, .table_category_form);
        },

        .form_table_category_name_edit => |event| model.form_table_category_name_buf.apply(event),

        .save_table_category => {
            const name = std.mem.trim(u8, model.form_table_category_name_buf.text(), " ");
            if (name.len == 0) {
                model.error_text = "The category needs a name";
                return;
            }
            const id = if (model.form_table_category_id != 0) model.form_table_category_id else fx.wallMs();
            model.busy = true;
            model.error_text = "";
            repos.saveTableCategory(fx, repos.key_save_table_category, id, name);
        },

        .table_category_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "The category could not be saved - try again";
                return;
            }
            model.error_text = "";
            publishReference(fx);
            repos.loadTableCategories(model, fx);
            go(model, .table_categories);
        },

        .db_table_count_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind != .page) return;
            var reader = repos.page.Reader.init(result.bytes);
            var values: [repos.page.max_columns]repos.page.Value = undefined;
            if (!reader.readHeader() or !reader.nextRow(&values)) return;
            model.db_table_count_field = reader.intOf(&values, "n", 0);
            // A database from a newer app: this one must not write to
            // it, so it says so instead of pretending to work.
            if (model.db_is_newer()) {
                model.error_text = "";
                go(model, .upgrade);
            }
        },

        .table_categories_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeTableCategories(model, result.bytes);
        },

        .open_modifier_groups => {
            go(model, .settings_modifiers);
            repos.loadModifierGroups(model, fx);
            repos.loadModifiers(model, fx);
        },

        .new_modifier_group => {
            model.form_modifier_group_id = 0;
            model.form_modifier_group_name_buf.set("");
            model.form_modifier_max_buf.set("1");
            model.form_modifier_required_field = false;
            go(model, .modifier_group_form);
        },

        .edit_modifier_group => |id| {
            model.form_modifier_group_id = id;
            model.form_modifier_group_name_buf.set("");
            model.form_modifier_max_buf.set("");
            model.form_modifier_required_field = false;
            for (model.modifier_groups_list) |group| {
                if (group.id != id) continue;
                model.form_modifier_group_name_buf.set(group.name);
                // The number of choices the group allows, as text. The
                // buffer takes the digits, written by hand: there is
                // no allocator in `update`.
                var digits: [20]u8 = undefined;
                var index = digits.len;
                var value = group.max_select;
                if (value == 0) value = 1;
                while (index > 0) {
                    index -= 1;
                    digits[index] = @intCast('0' + @as(u8, @intCast(@rem(value, 10))));
                    value = @divTrunc(value, 10);
                }
                model.form_modifier_max_buf.set(digits[index..]);
                model.form_modifier_required_field = group.required;
                break;
            }
            go(model, .modifier_group_form);
        },

        .form_modifier_group_name_edit => |event| model.form_modifier_group_name_buf.apply(event),

        .form_modifier_max_edit => |event| model.form_modifier_max_buf.apply(event),

        .form_modifier_required => model.form_modifier_required_field = !model.form_modifier_required_field,

        .save_modifier_group => {
            const name = std.mem.trim(u8, model.form_modifier_group_name_buf.text(), " ");
            if (name.len == 0) {
                model.error_text = "The group needs a name";
                return;
            }
            const max = std.fmt.parseInt(i64, std.mem.trim(u8, model.form_modifier_max_buf.text(), " "), 10) catch {
                model.error_text = "How many choices is a number";
                return;
            };
            if (max < 1) {
                model.error_text = "A group allows at least one choice";
                return;
            }
            const id = if (model.form_modifier_group_id != 0) model.form_modifier_group_id else fx.wallMs();
            model.busy = true;
            model.error_text = "";
            repos.saveModifierGroup(fx, repos.key_save_modifier_group, id, name, model.form_modifier_required_field, max);
        },

        .modifier_group_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "The group could not be saved - try again";
                return;
            }
            model.error_text = "";
            repos.loadModifierGroups(model, fx);
            go(model, .settings_modifiers);
        },

        .modifiers_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeModifiers(model, result.bytes);
        },

        .open_inventory => {
            go(model, .inventory_items);
            repos.loadStock(model, fx);
        },

        .open_db_inspector => {
            go(model, .db_inspector);
            repos.loadTableCounts(model, fx);
        },

        .open_control_center => {
            go(model, .control_center);
            repos.loadDevices(model, fx);
            repos.loadSyncState(model, fx);
        },

        .open_kitchen_dishes => {
            go(model, .kitchen_dishes);
            repos.loadProducts(model, fx);
            repos.loadStations(model, fx);
            repos.loadProductStations(model, fx);
        },

        .select_dish => |id| model.selected_dish_id = id,

        .assign_station => |station_id| {
            if (model.selected_dish_id == 0) {
                model.error_text = "Choose a dish first";
                return;
            }
            if (station_id == 0) {
                model.error_text = "That is not a station";
                return;
            }
            model.busy = true;
            model.error_text = "";
            repos.saveDishStation(fx, repos.key_save_station, model.selected_dish_id, station_id);
        },

        .db_tables_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "The tables could not be read - try again";
                return;
            }
            model.error_text = "";
            if (result.kind == .page) repos.decodeTableCounts(model, result.bytes);
        },

        .devices_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeDevices(model, result.bytes);
        },

        .sync_state_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) {
                repos.decodeSyncState(model, result.bytes);
                // A boot after a week may find a log that is already
                // past the policy. The durable counter survived the
                // restart; compact now rather than waiting for another
                // 128 ops.
                repos.maybeCompact(model, fx);
            }
        },

        .dish_assigned => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "The station could not be saved - try again";
                return;
            }
            model.error_text = "";
            repos.loadProductStations(model, fx);
        },

        .count_stock => |id| {
            model.form_stock_product_id = id;
            model.form_stock_name_field = "";
            for (model.stock_items_list) |item| {
                if (item.id != id) continue;
                model.form_stock_name_field = item.name;
                break;
            }
            // The form starts where the shelf is, so the owner types
            // the count they see, not the difference.
            model.form_stock_count_buf.set("");
            model.form_stock_reason_buf.set("");
            go(model, .stock_count);
        },

        .form_stock_count_edit => |event| model.form_stock_count_buf.apply(event),

        .form_stock_reason_edit => |event| model.form_stock_reason_buf.apply(event),

        .save_stock_count => {
            if (model.form_stock_product_id == 0) {
                model.error_text = "Nothing is being counted";
                return;
            }
            const typed = std.mem.trim(u8, model.form_stock_count_buf.text(), " \t");
            const qty = std.fmt.parseInt(i64, typed, 10) catch {
                model.error_text = "A count is a number";
                return;
            };
            if (qty < 0) {
                model.error_text = "A count cannot be negative";
                return;
            }
            const current = model.form_stock_current();
            const delta = qty - current;
            const reason = std.mem.trim(u8, model.form_stock_reason_buf.text(), " \t");
            if (reason.len == 0) {
                model.error_text = "Say why the count changed";
                return;
            }
            model.busy = true;
            model.error_text = "";
            repos.saveStockCount(
                model,
                fx,
                repos.key_save_stock,
                model.form_stock_product_id,
                qty,
                delta,
                reason,
                fx.wallMs(),
            );
        },

        .stock_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "The count could not be saved - try again";
                return;
            }
            model.error_text = "";
            repos.loadStock(model, fx);
            go(model, .inventory_items);
        },

        .stock_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "The stock could not be read - try again";
                return;
            }
            model.error_text = "";
            if (result.kind == .page) repos.decodeStock(model, result.bytes);
        },

        .open_tables => go(model, .dining_tables),

        // ---------------------------------------------------------- the POS
        .open_order => |id| {
            model.selected_order_id = id;
            model.void_reason_buf.set("");
            go(model, .order_detail);
            repos.loadOrderLines(model, fx);
        },

        .pay_selected_order => {
            const id = model.selected_order_id;
            if (id == 0) return;
            const order = findOrder(model, id) orelse return;
            if (!canTakePayment(model, order)) return;
            model.sale_buf.reset();
            model.last_order_id = order.id;
            model.last_order_no_field = model.sale_buf.dupe(order.order_no) orelse "";
            model.last_order_type_field = model.sale_buf.dupe(order.type_label) orelse "";
            model.last_order_total_minor = order.total_minor;
            model.last_order_items_count = 0;
            for (model.order_lines) |line| {
                if (line.order_id != order.id) continue;
                model.last_order_items_count += line.qty;
            }
            model.last_order_at = order.placed_at;
            model.payment_check_id = 0;
            model.payment_error = "";
            model.cash_tendered_buf.clear();
            go(model, .order_confirmation);
        },

        .pay_order => |id| {
            // The confirmation screen takes the money, so the sale state
            // is filled in from the order that is being paid.
            const order = findOrder(model, id) orelse return;
            if (!canTakePayment(model, order)) return;
            model.sale_buf.reset();
            model.last_order_id = order.id;
            model.last_order_no_field = model.sale_buf.dupe(order.order_no) orelse "";
            model.last_order_type_field = model.sale_buf.dupe(order.type_label) orelse "";
            model.last_order_total_minor = order.total_minor;
            model.last_order_items_count = 0;
            for (model.order_lines) |line| {
                if (line.order_id != order.id) continue;
                model.last_order_items_count += line.qty;
            }
            model.last_order_at = order.placed_at;
            model.payment_check_id = 0;
            model.payment_error = "";
            model.cash_tendered_buf.clear();
            go(model, .order_confirmation);
        },

        .search_edit => |event| model.search.apply(event),

        .set_category => |id| model.selected_category = id,

        .set_category_all => model.selected_category = 0,

        .add_to_cart => |product_id| {
            if (canEditCart(model)) addToCart(model, product_id);
        },

        .remove_from_cart => |product_id| {
            if (canEditCart(model)) removeFromCart(model, product_id);
        },

        .set_order_type => |index| {
            const next = std.enums.fromInt(domain.OrderType, index) orelse return;
            if (!canEditCart(model)) return;
            if (model.cart_order_type != next) model.cart_attempt_id = 0;
            model.cart_order_type = next;
        },

        .apply_discount => |discount_id| {
            if (!canEditCart(model)) return;
            for (model.discounts_list) |discount| {
                if (discount.id != discount_id) continue;
                if (!discount.active) break;
                if (model.cart_discount_id != discount_id) model.cart_attempt_id = 0;
                model.cart_discount_id = discount_id;
                model.error_text = "";
                return;
            }
            model.error_text = "That discount is not one you can use";
        },

        .clear_discount => {
            if (!canEditCart(model)) return;
            if (model.cart_discount_id != 0) model.cart_attempt_id = 0;
            model.cart_discount_id = 0;
        },

        .clear_cart => {
            if (!canEditCart(model)) return;
            model.cart_len = 0;
            model.cart_buf.reset();
            model.cart_attempt_id = 0;
        },

        .place_order => placeOrder(model, fx, false),
        .hold_cart => placeOrder(model, fx, true),

        .order_placed => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                // The operator is told WHAT failed, not just that
                // something did: a rejected order is a data problem
                // (a table that no longer exists, a product that was
                // deleted mid-sale) and a busy database is not.
                model.error_text = switch (result.outcome) {
                    .constraint => "The order broke a data rule - check the table and the products",
                    .busy => "The database is busy - try again",
                    .misuse => "The order was malformed",
                    .io_failed => "Storage error - the order was not saved",
                    else => "Could not save the order",
                };
                // The sale did not happen, so the cart is still the
                // cashier's: the button comes back and the sale can be
                // tried again.
                model.sale_pending = false;
                model.cart_hold_pending = false;
                return;
            }
            model.sale_pending = false;
            if (model.cart_hold_pending) {
                model.cart_hold_pending = false;
                model.cart_len = 0;
                model.cart_buf.reset();
                model.cart_attempt_id = 0;
                model.error_text = "";
                repos.loadOrders(model, fx);
                net_bridge.notify();
                repos.maybeCompact(model, fx);
                return;
            }
            model.cart_len = 0;
            model.cart_buf.reset();
            // The sale landed: the next sale is a new attempt, with its
            // own id and its own request key.
            model.cart_attempt_id = 0;
            go(model, .order_confirmation);
            repos.loadOrders(model, fx);
            // The order is in the op log. The other apps' boards wake
            // now instead of waiting for the five-second poll.
            net_bridge.notify();
            repos.maybeCompact(model, fx);
        },

        // ----------------------------------------------------- the waiter

        .select_table => |table_id| selectTable(model, fx, table_id),

        .go_waiter_tables => go(model, .waiter_tables),

        .go_waiter_menu => go(model, .waiter_menu),

        .go_waiter_cart => go(model, .waiter_cart),

        .order_opened => |result| {
            if (result.outcome != .ok) {
                model.error_text = "Could not open the table";
                return;
            }
            // The order exists: the waiter can add to it. Read the
            // board back now, so a second tap on the same table joins
            // this order instead of opening another.
            model.active_order_id = model.pending_order_id;
            model.pending_order_id = 0;
            go(model, .waiter_menu);
            repos.loadOrderLines(model, fx);
            repos.loadOrders(model, fx);
        },

        .add_to_order => |product_id| addToOrder(model, fx, product_id),

        .order_line_added => |result| {
            model.add_line_pending = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not add the item";
                return;
            }
            // The line is on the order: read the order back so the
            // waiter sees the running total.
            repos.loadOrderLines(model, fx);
            repos.loadOrders(model, fx);
        },

        // ---------------------------------------------------- the payment

        .set_payment_mode => |id| model.payment_mode_field = id,

        .cash_tendered_edit => |event| model.cash_tendered_buf.apply(event),

        .take_payment => takePayment(model, fx),

        .back_to_pos => {
            // The sale is over: the confirmation state goes, and the
            // next order starts from an empty cart.
            model.last_order_id = 0;
            model.last_order_no_field = "";
            model.last_order_type_field = "";
            model.last_order_total_minor = 0;
            model.last_order_items_count = 0;
            model.payment_check_id = 0;
            model.payment_error = "";
            model.cash_tendered_buf.clear();
            go(model, .pos);
        },

        .payment_taken => |result| {
            model.busy = false;
            model.payment_pending = false;
            if (result.outcome != .ok) {
                model.payment_check_id = 0;
                model.payment_error = switch (result.outcome) {
                    .constraint => "The payment broke a data rule",
                    .busy => "The database is busy - try again",
                    else => "Could not take the payment",
                };
                // The refusal may be a late plate: re-read the board so
                // the confirmation shows the bill the next tap will
                // charge, not the one that was refused.
                repos.loadOrders(model, fx);
                return;
            }
            model.payment_error = "";
            // The write is reported as success even when its guards
            // found a late plate or a ticket that moved. Read the board
            // back under the payment-check key and let the order's own
            // row decide whether the money landed before telling the
            // cashier the sale is done.
            if (model.last_order_id != 0) {
                model.payment_check_id = model.last_order_id;
                repos.loadOrdersForPayment(model, fx);
            } else {
                go(model, .orders);
                net_bridge.notify();
                repos.maybeCompact(model, fx);
            }
        },

        // -------------------------------------------------------- the forms

        .form_currency_code_edit => |event| model.form_currency_code_buf.apply(event),

        .form_currency_symbol_edit => |event| model.form_currency_symbol_buf.apply(event),

        .save_currency => {
            const code = std.mem.trim(u8, model.form_currency_code_buf.text(), " ");
            const symbol = std.mem.trim(u8, model.form_currency_symbol_buf.text(), " ");
            if (code.len == 0) {
                model.error_text = "The currency needs a code";
                return;
            }
            model.busy = true;
            repos.saveCurrency(
                fx,
                repos.key_save_currency,
                code,
                if (symbol.len == 0) "$" else symbol,
                model_mod.decimalsForCurrency(code),
            );
        },

        .currency_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the currency";
                return;
            }
            model.error_text = "";
            publishReference(fx);
            repos.loadCompany(model, fx);
        },

        .form_product_name_edit => |event| model.form_product_name_buf.apply(event),

        .form_product_price_edit => |event| model.form_product_price_buf.apply(event),

        .form_product_category => |id| model.form_product_category_id = id,

        .form_product_food => |id| model.form_product_food_id = id,

        .open_catalogue => go(model, .product_categories),

        .open_categories => go(model, .categories),

        .edit_product => |id| openProductForm(model, id),

        .new_product => openProductForm(model, 0),

        .save_product => saveProduct(model, fx),

        .product_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the product";
                return;
            }
            model.error_text = "";
            publishReference(fx);
            repos.loadProducts(model, fx);
            repos.loadCategories(model, fx);
            go(model, .product_categories);
        },

        .form_employee_name_edit => |event| model.form_employee_name_buf.apply(event),

        .form_employee_role => |id| model.form_employee_role_id = id,

        .edit_employee => |id| openEmployeeForm(model, id),

        .open_employees => go(model, .employees),

        .reset_employee_credential => |id| {
            model.form_reset_employee_id = id;
            model.form_reset_employee_name = "";
            model.form_reset_credential_buf.clear();
            model.form_reset_credential2_buf.clear();
            // The form opens on the kind this person uses today, so the
            // owner sees what is there before they change it.
            model.form_reset_credential_kind = .pin;
            model.credential_revealed = false;
            for (model.employees) |employee| {
                if (employee.id != id) continue;
                model.form_reset_employee_name = employee.name;
                model.form_reset_credential_kind = employee.auth_kind;
                break;
            }
            go(model, .reset_credential);
        },

        .form_reset_credential_edit => |event| applySecretEdit(&model.form_reset_credential_buf, event),

        .form_reset_credential2_edit => |event| applySecretEdit(&model.form_reset_credential2_buf, event),

        .form_reset_credential_kind => |id| {
            model.form_reset_credential_kind = domain.CredentialKind.fromInt(id) orelse .pin;
        },

        .save_reset_credential => {
            const secret = model.form_reset_credential_buf.text();
            const kind = model.form_reset_credential_kind;
            if (model.form_reset_employee_id == 0) {
                model.error_text = "Nobody is having their sign-in reset";
                return;
            }
            if (!model.credential_is_acceptable(kind, secret)) {
                model.error_text = switch (kind) {
                    .pin => "A PIN is six digits or more, and digits only",
                    .password => "A password is eight characters or more",
                };
                return;
            }
            if (!std.mem.eql(u8, secret, model.form_reset_credential2_buf.text())) {
                model.error_text = switch (kind) {
                    .pin => "The two PINs do not match",
                    .password => "The two passwords do not match",
                };
                return;
            }
            var hash: [auth.hash_length]u8 = undefined;
            const hashed = auth.hashCredential(model.salt(), model.form_reset_employee_id, secret, &hash) orelse {
                model.error_text = "Could not hash the credential - try again";
                return;
            };
            model.busy = true;
            model.error_text = "";
            // The kind is written with the hash. There is no way to
            // change one without the other, which is the point: a
            // person left with a surface they never chose is a person
            // who is locked out of their own till.
            repos.saveEmployeeCredential(fx, repos.key_save_employee, model.form_reset_employee_id, hashed, @intFromEnum(kind));
        },

        .employee_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the employee";
                return;
            }
            model.error_text = "";
            publishReference(fx);
            repos.loadEmployees(model, fx);
            go(model, .employees);
        },

        .new_employee => openEmployeeForm(model, 0),

        .save_employee => saveEmployee(model, fx),

        .reservations_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeReservations(model, result.bytes);
        },

        .suppliers_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeSuppliers(model, result.bytes);
        },

        .purchase_orders_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodePurchaseOrders(model, result.bytes);
        },

        .inventory_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeProducts(model, result.bytes);
        },

        .printers_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodePrinters(model, result.bytes);
        },

        .edit_tax_slab => |id| openTaxSlabForm(model, id),

        .new_tax_slab => openTaxSlabForm(model, 0),

        .save_tax_slab => saveTaxSlab(model, fx),

        .open_tax_slabs => go(model, .settings_tax),

        .tax_slab_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the tax slab";
                return;
            }
            model.error_text = "";
            publishReference(fx);
            repos.loadTaxSlabs(model, fx);
            go(model, .settings_tax);
        },

        .form_tax_slab_name_edit => |event| model.form_tax_slab_name_buf.apply(event),

        .form_tax_slab_rate_edit => |event| model.form_tax_slab_rate_buf.apply(event),

        .form_tax_slab_inclusive => model.form_tax_slab_inclusive = !model.form_tax_slab_inclusive,

        .tax_slabs_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeTaxSlabs(model, result.bytes);
        },

        .modifier_groups_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeModifierGroups(model, result.bytes);
        },

        .edit_category => |id| openCategoryForm(model, id),

        .new_category => openCategoryForm(model, 0),

        .save_category => saveCategory(model, fx),

        .category_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the category";
                return;
            }
            model.error_text = "";
            publishReference(fx);
            repos.loadCategories(model, fx);
            go(model, .product_categories);
        },

        .form_category_name_edit => |event| model.form_category_name_buf.apply(event),

        .edit_discount => |id| openDiscountForm(model, id),

        .new_discount => openDiscountForm(model, 0),

        .save_discount => saveDiscount(model, fx),

        .open_discounts => go(model, .settings_discounts),

        .discount_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the discount";
                return;
            }
            model.error_text = "";
            repos.loadDiscounts(model, fx);
            go(model, .settings_discounts);
        },

        .form_discount_name_edit => |event| model.form_discount_name_buf.apply(event),

        .form_discount_percent_edit => |event| model.form_discount_percent_buf.apply(event),

        .form_discount_amount_edit => |event| model.form_discount_amount_buf.apply(event),

        .discounts_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeDiscounts(model, result.bytes);
        },

        // ------------------------------------------------ the company form

        .form_company_name_edit => |event| model.form_name_buf.apply(event),

        .form_company_address_edit => |event| model.form_address_buf.apply(event),

        .form_company_phone_edit => |event| model.form_phone_buf.apply(event),

        .form_company_tax_edit => |event| model.form_tax_buf.apply(event),

        .form_company_brand_edit => |event| model.form_brand_buf.apply(event),

        .save_company => saveCompany(model, fx),

        .open_settings => go(model, .settings),

        .company_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the company";
                return;
            }
            model.error_text = "";
            publishReference(fx);
            // Read it back: the form's buffers are the edit model, and
            // the company row is the truth.
            repos.loadCompany(model, fx);
        },

        // --------------------------------------------------------- pairing

        .pairing_edit => |event| model.pairing_entry.apply(event),

        .save_pairing => savePairing(model, fx),

        // -------------------------------------------------- the kitchen board

        .refresh_orders => |timer| {
            if (timer.outcome != .fired) return;
            repos.loadOrders(model, fx);
        },

        .set_station_filter => |id| model.station_filter_field = id,

        .set_station_filter_all => model.station_filter_field = 0,

        .stations_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeStations(model, result.bytes);
        },

        .product_stations_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeProductStations(model, result.bytes);
        },

        .audio_event => |event| {
            // The chime's own outcome. A failed chime is not the
            // operator's problem: the board still shows the order.
            _ = event;
        },

        .advance_order => |order_id| {
            // One move at a time. A second tap would compute the next
            // status from a model that has not caught up yet, and skip a
            // state on the way.
            if (model.advance_order_id != 0) {
                model.error_text = "The order is still being updated";
                return;
            }
            const order = findOrder(model, order_id) orelse {
                model.error_text = "That order is no longer on the board";
                return;
            };
            const next = nextStatus(order.status);
            // An order does not close without the money. The last step
            // of the lifecycle is the payment, and the kitchen cannot
            // take it - so a ticket that has not been paid for stops
            // here, and says why.
            if (next == .completed and !order.paid) {
                model.error_text = "Take the money before closing the order";
                return;
            }
            model.advance_order_id = order_id;
            model.busy = true;
            repos.setOrderStatus(model, fx, order_id, order.status, next, fx.wallMs());
        },

        .void_order => |order_id| {
            // A void is a move like any other: one at a time, and only
            // for an order that is still open. A paid order is money
            // that has changed hands - putting it back is a refund,
            // not a void, and it has to name the tender it came from.
            if (model.advance_order_id != 0) {
                model.error_text = "The order is still being updated";
                return;
            }
            const order = findOrder(model, order_id) orelse {
                model.error_text = "That order is no longer on the board";
                return;
            };
            if (order.status == .voided) {
                model.error_text = "This order is already voided";
                return;
            }
            const reason = std.mem.trim(u8, model.void_reason_buf.text(), " ");
            if (reason.len == 0) {
                model.error_text = "Say why the order is being voided";
                return;
            }
            // A paid void owes the money back. The refund is recorded
            // after the void lands, so a failed void never writes one.
            model.refund_pending = order.paid;
            model.advance_order_id = order_id;
            model.voiding_order_id = order_id;
            model.busy = true;
            model.error_text = "";
            repos.voidOrder(model, fx, order_id, reason, fx.wallMs());
        },

        .hold_order => |order_id| {
            const order = findOrder(model, order_id) orelse {
                model.error_text = "That order is no longer on the board";
                return;
            };
            if (order.status == .held) {
                model.error_text = "This order is already held";
                return;
            }
            model.advance_order_id = order_id;
            model.busy = true;
            model.error_text = "";
            repos.setOrderStatus(model, fx, order_id, order.status, .held, fx.wallMs());
        },

        .void_reason_edit => |event| model.void_reason_buf.apply(event),

        .credential_rehashed => |result| {
            // The rewrite is a courtesy: the sign-in has already
            // happened, and a row that could not be rewritten is worth
            // knowing about but not worth failing over.
            if (result.outcome != .ok) {
                model.error_text = "The stored credential could not be upgraded - it still works";
            } else {
                // The employee's hash is reference data: the peer's
                // copy would otherwise stay on the old hash.
                publishReference(fx);
            }
        },

        .order_status_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.advance_order_id = 0;
                model.voiding_order_id = 0;
                model.error_text = "Could not update the order";
                return;
            }
            // The orders come back with the status the DATABASE has,
            // not the one the model guessed: the board shows the truth
            // and the next move is computed from it.
            repos.loadOrders(model, fx);
            net_bridge.notify();
            repos.maybeCompact(model, fx);
            if (model.refund_pending) {
                model.refund_pending = false;
                const reason = std.mem.trim(u8, model.void_reason_buf.text(), " ");
                repos.recordRefund(model, fx, model.voiding_order_id, reason, fx.wallMs());
            }
        },

        // -------------------------------------------------------------- data

        .products_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "Could not load the menu";
                return;
            }
            if (result.kind == .page) repos.decodeProducts(model, result.bytes);
        },

        .categories_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeCategories(model, result.bytes);
        },

        .tables_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "Could not load the tables";
                return;
            }
            if (result.kind == .page) repos.decodeTables(model, result.bytes);
        },

        .employees_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeEmployees(model, result.bytes);
        },

        .customers_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeCustomers(model, result.bytes);
        },

        .report_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "The report could not be read - try again";
                return;
            }
            model.error_text = "";
            if (result.kind == .page) repos.decodeReport(model, result.bytes);
        },

        .report_modes_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "The report could not be read - try again";
                return;
            }
            model.error_text = "";
            if (result.kind == .page) repos.decodeReportModes(model, result.bytes);
        },

        .payments_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "The payments could not be read - try again";
                return;
            }
            model.error_text = "";
            if (result.kind == .page) repos.decodePayments(model, result.bytes);
        },

        .orders_loaded => |result| {
            if (result.outcome != .ok) {
                // A board that cannot read the orders is a board that
                // silently shows the wrong thing. Say so.
                model.error_text = switch (result.outcome) {
                    .rejected => "The order list is busy - try again",
                    .busy => "The database is busy - try again",
                    else => "Could not read the orders",
                };
                if (result.key == repos.key_payment_check and model.payment_check_id != 0) {
                    model.payment_check_id = 0;
                    model.payment_error = "Could not confirm the payment - try again";
                }
                return;
            }
            if (result.kind == .page) {
                repos.decodeOrders(model, result.bytes);
                announceNewOrder(model, fx);
            }
            // The payment's write reports success even when its guards
            // refused it. Wait for the payment's own board read, then
            // check the order's payment row before calling the sale
            // done.
            if (result.key == repos.key_payment_check and result.kind == .done) settlePayment(model, fx);
            // The order we were moving is not on the board any more. It
            // was deleted, or the database was reset under us, and the
            // operator is told so instead of watching a ticket vanish.
            if (model.advance_order_id != 0) {
                const moved = findOrder(model, model.advance_order_id);
                const was_void = model.voiding_order_id != 0 and model.voiding_order_id == model.advance_order_id;
                if (moved == null) {
                    if (was_void) {
                        // The void landed: the order is off the open
                        // board, so leave the detail screen with it.
                        model.error_text = "";
                        model.void_reason_buf.set("");
                        go(model, .orders);
                    } else {
                        model.error_text = "That order is no longer on the board";
                    }
                } else if (was_void) {
                    // The write was accepted but the database did not
                    // move the order - it was paid or voided elsewhere.
                    // Say so instead of pretending the void happened.
                    model.error_text = "The order could not be voided - it may have been paid";
                }
                model.advance_order_id = 0;
                model.voiding_order_id = 0;
            }
        },

        .order_lines_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeOrderLines(model, result.bytes);
            keepActiveOrder(model);
        },

        .config_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = switch (result.outcome) {
                    .busy => "The database is busy - try again",
                    .corrupt => "The database is damaged",
                    else => "Could not read the installation settings",
                };
                return;
            }
            switch (result.kind) {
                .page => {
                    var reader = page.Reader.init(result.bytes);
                    var values: [page.max_columns]page.Value = undefined;
                    if (!reader.readHeader()) return;
                    var has_salt = reader.nextRow(&values);
                    if (has_salt and reader.textOf(&values, "value").len == 0) has_salt = false;
                    if (!has_salt) {
                        // The database has NO salt: this is a fresh
                        // installation, and the salt in the model is
                        // the one it will use. The setup writes it with
                        // the operator's hash.
                        //
                        // If we just wrote a salt and the read does not
                        // find one, the write did not land. Retrying here
                        // would loop; block sign-in and say so.
                        if (model.salt_state == .verifying) {
                            model.salt_state = .unknown;
                            model.error_text = "The installation settings did not save";
                            return;
                        }
                        model.salt_state = .installing;
                        return;
                    }
                    const salt = reader.textOf(&values, "value");
                    const copied = model.salt_buf[0..];
                    const length = @min(salt.len, copied.len);
                    @memcpy(copied[0..length], salt[0..length]);
                    model.salt_len = length;
                    // The database has the salt now: it is the salt a
                    // sign-in has to use.
                    model.salt_state = .confirmed;
                    // The salt is what the employee hashes were made
                    // with, so the document can be built (admin) or its
                    // version read (peer) only now.
                    if (model_mod.app_kind == .admin) {
                        repos.loadReferenceSnapshot(model, fx);
                    } else {
                        repos.loadReferenceVersion(model, fx);
                    }
                },
                .done => {
                    // The settings query finished. If the database had
                    // no salt, this is a fresh installation and the
                    // provisional salt the app made at boot is the one
                    // that counts - so store it.
                    if (model.salt_state == .installing) createSalt(model, fx);
                },
                .exec => {},
            }
        },

        .config_saved => |result| {
            if (result.outcome == .ok) {
                // `ON CONFLICT DO NOTHING` reports success even when a
                // second instance stored a different salt first. The
                // write alone is not proof: read the salt back, and let
                // `config_loaded` confirm the one the database holds.
                model.salt_state = .verifying;
                repos.loadConfig(model, fx);
                return;
            }
            // The salt did not land. The model keeps the provisional
            // salt, and a sign-in stays refused until the write works -
            // a sign-in against a salt that is not stored can never be
            // verified, and the operator would be locked out with no
            // way to tell why.
            model.error_text = switch (result.outcome) {
                .busy => "The database is busy - try again",
                .constraint => "The installation settings could not be saved",
                else => "Could not save the installation settings",
            };
        },

        .theme_loaded => |result| {
            // The look of the device is a preference, so a read that
            // failed is not something to tell the operator: the screen
            // is already drawing in the default.
            if (result.outcome != .ok) return;
            if (result.kind != .page) return;
            // Asked for at boot, and it can land after the tap it would
            // otherwise undo. The choice the operator made is the truth.
            if (model.theme_chosen) return;
            repos.decodeTheme(model, result.bytes);
        },

        .theme_saved => |result| {
            // The screen already wears the palette. A write that did not
            // land means only that the next boot puts the device back.
            if (result.outcome == .ok) return;
            model.error_text = "The look of this device could not be saved";
        },

        .pairing_loaded => |result| {
            // A read that failed leaves whatever this device came up with
            // in place. A device that cannot ask its database is still a
            // device its own peers can reach, and the count of requests
            // turned away is the sign that something is off - not a
            // banner, because nothing the operator can do fixes a database
            // that will not answer.
            if (result.outcome != .ok) return;
            if (result.kind != .page) return;
            var reader = page.Reader.init(result.bytes);
            var values: [page.max_columns]page.Value = undefined;
            var stored: []const u8 = "";
            if (reader.readHeader() and reader.nextRow(&values)) {
                stored = reader.textOf(&values, "value");
            }
            if (stored.len == 0) {
                // The database has no token of its own. This device's
                // value - the one it was given, or the one it made at boot
                // - becomes the restaurant's, and is stored where a peer
                // started from the same database will read it back.
                net_bridge.sharePairing(model);
                repos.savePairing(fx, model.pairing(), fx.wallMs());
                return;
            }
            // The database's value is the one the wire checks: it is the
            // value the other devices were handed. A token this device
            // made for itself steps aside for it, exactly as a provisional
            // salt does.
            const copied = model.pairing_buf[0..];
            const length = @min(stored.len, copied.len);
            @memcpy(copied[0..length], stored[0..length]);
            model.pairing_len = length;
            net_bridge.sharePairing(model);
        },

        .pairing_saved => |result| {
            // The device is already using this token, on both halves of
            // the wire. A write that did not land means the next boot puts
            // the device back to the value the database holds - and the
            // peers that were handed the new one stop being recognised,
            // which the count of refusals will say.
            if (result.outcome == .ok) return;
            model.error_text = "The pairing token could not be stored";
        },

        .company_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeCompany(model, result.bytes);
            model.db_ready = true;
            // No company row: this is a fresh installation. Only the
            // admin app is the restaurant's writer; a service or kiosk
            // that started first waits for its reference data rather
            // than inventing a second restaurant with an admin who
            // cannot sign in on a waiter binary.
            if (model.company_id == 0 and !model.needs_setup and !model.waiting_for_reference) {
                if (model_mod.app_kind == .admin) {
                    model.needs_setup = true;
                    // A fresh install opens on the walk-through: the
                    // company's record first, then the owner.
                    model.stack.resetTo(.create_company);
                    model.setup_currency_code.set("USD");
                    model.setup_currency_symbol.set("$");
                    // The walk-through is the way in: the company's
                    // record first, then the owner and the credential
                    // they choose.
                    resetNavigation(model, .create_company);
                } else {
                    model.waiting_for_reference = true;
                    resetNavigation(model, .role_picker);
                }
            } else if (model.company_id != 0 and model.waiting_for_reference) {
                // The admin's document arrived: this terminal now has
                // the restaurant, the people and the menu it needed.
                model.waiting_for_reference = false;
                if (!model.signed_in and !model.role_chosen) {
                    resetNavigation(model, .role_picker);
                }
            }
        },

        .db_failed => |result| {
            model.busy = false;
            model.error_text = switch (result.outcome) {
                .busy => "The database is busy - try again",
                .io_failed => "Storage error",
                .corrupt => "The database is damaged",
                else => "The database refused the request",
            };
        },

        // ----------------------------------------------------------- chrome

        .dismiss_error => model.error_text = "",

        .retry_read => {
            // The read that failed belongs to a screen, and the retry
            // reads what THAT screen shows - not what is on the pane
            // now, which may be somewhere else by now.
            const screen = model.failed_screen;
            model.read_failed = false;
            model.error_text = "";
            model.reading = true;
            model.read_started_at = model.now_ms;
            repos.loadForScreen(model, fx, screen);
        },

        // The glyph promises the other half of the day, so this lands on
        // one of the two palettes it names. All four are Settings' to
        // offer, and the contrast is a setting of its own.
        .toggle_theme => chooseTheme(model, fx, model.theme_palette.otherHalf(), model.theme_contrast_high),
        .set_palette => |code| chooseTheme(model, fx, model_mod.Palette.fromCode(code), model.theme_contrast_high),
        .toggle_contrast => chooseTheme(model, fx, model.theme_palette, !model.theme_contrast_high),

        .refund_recorded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "The void landed, but the refund could not be recorded";
            }
        },

        .tick => |timer| {
            if (timer.outcome != .fired) return;
            const now = fx.wallMs();

            // The clock is only worth repainting for the screens that
            // show a wait time. Other screens do not read now_ms, so
            // storing it every second would rebuild the whole app for
            // nothing.
            if (model.screen() == .kds_board or model.screen() == .display_board) {
                model.now_ms = now;
            }

            // A peer that has gone quiet is gone; a manual address is
            // not. Then pull what is new. Five seconds is the beacon
            // interval, so a pull sees a peer the next beacon refreshed.
            model.prunePeers(now - 15_000);
            if (now >= model.sync_poll_at_ms) {
                model.sync_poll_at_ms = now + 5_000;
                net_bridge.poll(model, fx);
            }
        },
    }
}

// ------------------------------------------------------------- helpers

/// Move the reference version after a save the admin made.
///
/// The admin is the only writer, and a peer asks "what is above my
/// version?" - so a catalogue edit is not visible until the counter
/// moves. The bump is a separate transaction that runs after the save
/// committed, and its result rebuilds the document.
fn publishReference(fx: *Effects) void {
    if (model_mod.app_kind != .admin) return;
    repos.bumpReferenceVersion(fx);
}

/// Move to a screen, refusing destinations the role may not open.
fn go(model: *Model, screen: Screen) void {
    if (!rbac.allows(model.role, screen)) {
        model.error_text = "This role cannot open that screen";
        return;
    }
    model.stack.push(screen);
    model.screen_index = screen.index();
    model.nav_section = sectionIndex(screen);
}

/// End the current session and land on `gate`.
///
/// This is the ONLY place session state is torn down. Sign-out, role
/// change, a successful sign-in and the setup hand-off all come through
/// here, so "what survives a session" has one answer rather than four.
///
/// The person the sign-in gate is asking about is the exception, and it
/// is the caller's business: a successful sign-in ends that choice, and
/// a sign-out hands the gate back to the person who just left. The two
/// answers are opposite, so no single reset could give both.
///
/// Device settings are deliberately kept: the theme, the split widths,
/// the KDS station filter, the installation salt and the device token
/// belong to the machine, not to the operator.
fn resetSession(model: *Model, gate: Screen) void {
    model.signed_in = false;
    model.employee_id = 0;
    model.employee_name = "";
    model.operator_buf.reset();
    model.credential.clear();
    // Both of these are the last person's, not the machine's: which
    // surface the sign-in offers belongs to whoever is chosen next, and
    // a secret left on the screen in the clear is a secret left for the
    // next person to read.
    model.credential_kind = .pin;
    model.credential_revealed = false;
    model.login_error = "";

    // Nothing the last operator put in the cart or typed into a filter
    // belongs to the next one.
    model.cart_len = 0;
    model.cart_buf.reset();
    model.cart_order_type = .dine_in;
    model.cart_discount_id = 0;
    model.cart_attempt_id = 0;
    model.sale_pending = false;
    model.payment_pending = false;
    model.add_line_pending = false;
    model.void_reason_buf.set("");
    model.voiding_order_id = 0;
    model.search.set("");
    model.selected_category = 0;

    // The waiter's table and its copy of the order lines are session
    // state too.
    model.active_table_id = 0;
    model.active_table_name = "";
    model.active_table_name_field = "";
    model.active_order_id = 0;
    model.pending_order_id = 0;
    model.active_lines = &.{};
    model.waiter_buf.reset();
    model.waiter_lines_buf.reset();

    // The last sale, the detail selection and every form belong to the
    // session that created them.
    model.selected_order_id = 0;
    model.last_order_id = 0;
    model.last_order_no_field = "";
    model.last_order_type_field = "";
    model.last_order_total_minor = 0;
    model.last_order_items_count = 0;
    model.last_order_at = 0;
    model.payment_check_id = 0;
    model.sale_buf.reset();
    model.payment_error = "";
    model.cash_tendered_buf.clear();
    model.advance_order_id = 0;

    model.form_currency_code_buf.set("");
    model.form_currency_symbol_buf.set("");
    model.form_product_name_buf.set("");
    model.form_product_price_buf.set("");
    model.form_product_category_id = 0;
    model.form_product_food_id = 0;
    model.form_product_id = 0;
    model.form_employee_name_buf.set("");
    model.form_employee_role_id = 0;
    model.form_employee_id = 0;
    model.form_name_buf.set("");
    model.form_address_buf.set("");
    model.form_phone_buf.set("");
    model.form_tax_buf.set("");
    model.form_brand_buf.set("");

    model.error_text = "";
    model.setup_error = "";
    model.busy = false;

    // History is a session thing. `gate` is the only entry behind the
    // first screen, so Back cannot reach the previous session.
    resetNavigation(model, gate);
}

/// Land on a screen with no history behind it.
fn resetNavigation(model: *Model, gate: Screen) void {
    model.stack.resetTo(gate);
    model.screen_index = gate.index();
    model.nav_section = sectionIndex(gate);
}

/// The nav section a screen belongs to, as the index the rail uses.
fn sectionIndex(screen: Screen) usize {
    const section = screen.nav_section() orelse return 0;
    return section.index();
}

fn addToCart(model: *Model, product_id: i64) void {
    for (model.cart[0..model.cart_len], 0..) |line, index| {
        if (line.product_id == product_id) {
            model.cart[index].qty += 1;
            // The ticket changed, so a retry is no longer the same
            // sale. A fresh attempt gets a fresh request key.
            model.cart_attempt_id = 0;
            return;
        }
    }
    if (model.cart_len >= model_mod.max_cart_lines) return;
    const product = findProduct(model, product_id) orelse return;
    const name = model.cart_buf.dupe(product.name) orelse return;
    model.cart[model.cart_len] = .{
        .product_id = product.id,
        .name = name,
        .price_minor = product.price_minor,
        .qty = 1,
    };
    model.cart_len += 1;
    model.cart_attempt_id = 0;
}

fn removeFromCart(model: *Model, product_id: i64) void {
    var index: usize = 0;
    while (index < model.cart_len) : (index += 1) {
        if (model.cart[index].product_id != product_id) continue;
        if (model.cart[index].qty > 1) {
            model.cart[index].qty -= 1;
            model.cart_attempt_id = 0;
            return;
        }
        // Drop the line and shift the rest down.
        var next = index + 1;
        while (next < model.cart_len) : (next += 1) {
            model.cart[next - 1] = model.cart[next];
        }
        model.cart_len -= 1;
        model.cart_attempt_id = 0;
        return;
    }
}

fn findProduct(model: *const Model, product_id: i64) ?domain.Product {
    for (model.products) |product| {
        if (product.id == product_id) return product;
    }
    return null;
}

fn findTable(model: *const Model, table_id: i64) ?domain.DiningTable {
    for (model.tables) |table| {
        if (table.id == table_id) return table;
    }
    return null;
}

fn findOrder(model: *const Model, order_id: i64) ?domain.Order {
    for (model.orders) |order| {
        if (order.id == order_id) return order;
    }
    return null;
}

/// Whether the cart may change right now. While a sale is being
/// written the database already has its copy of the ticket; an edit
/// would either be lost when the sale lands or be missing from the
/// order that was saved. The edit waits for the answer.
fn canEditCart(model: *Model) bool {
    if (model.sale_pending) {
        model.error_text = "The sale is still being saved";
        return false;
    }
    return true;
}

/// Whether the confirmation screen may open for this order. A closed
/// ticket has already taken its money; the list stops offering it, and
/// a message that arrives anyway must not reopen the sale.
fn canTakePayment(model: *Model, order: domain.Order) bool {
    if (order.paid or order.status == .completed) {
        model.error_text = "That order is already paid";
        return false;
    }
    if (order.status == .voided) {
        model.error_text = "A voided order cannot be paid";
        return false;
    }
    return true;
}

/// The order lifecycle. A voided order is terminal - it never moves
/// forward again.
fn nextStatus(status: domain.OrderStatus) domain.OrderStatus {
    return switch (status) {
        .pending => .preparing,
        .preparing => .ready,
        .ready => .served,
        .served => .completed,
        .completed, .voided, .held => status,
    };
}

/// Apply an edit to a field that is showing a mask rather than its own
/// text.
///
/// The runtime sends edits that are relative to the caret - a typed
/// character, a backspace, a word deleted - so those land correctly on
/// the secret however the field is drawn. A caret or selection event is
/// not relative: it is a byte offset into what the field SHOWS, and a
/// bullet is three bytes where a character of the secret is one. Letting
/// one through would put the caret into the middle of the secret on the
/// strength of where it stood in the dots, and the next key would splice
/// the secret in half. So the caret of a masked field is pinned to the
/// end, which is also what a masked field ought to do: you type a secret
/// at the end of it.
fn applySecretEdit(buffer: anytype, event: canvas.TextInputEvent) void {
    switch (event) {
        .insert_text,
        .delete_backward,
        .delete_forward,
        .delete_word_backward,
        .delete_word_forward,
        .delete_to_start,
        .delete_to_line_start,
        .clear,
        => buffer.apply(event),
        else => buffer.selection = canvas.TextSelection.collapsed(buffer.len),
    }
}

/// The sign-in's three hard sentences, each in the word this person uses
/// for their own secret. Telling somebody their PIN is wrong when the
/// screen wanted a password sends them to a colleague for help instead
/// of to the keyboard, and a sign-in screen that reads as broken is the
/// one thing a restaurant cannot afford at lunch.
fn wrongSecret(kind: domain.CredentialKind) []const u8 {
    return switch (kind) {
        .pin => "Wrong PIN",
        .password => "Wrong password",
    };
}

fn missingSecret(kind: domain.CredentialKind) []const u8 {
    return switch (kind) {
        .pin => "Enter your PIN",
        .password => "Enter your password",
    };
}

fn noSecret(kind: domain.CredentialKind) []const u8 {
    return switch (kind) {
        .pin => "That person has no PIN yet",
        .password => "That person has no password yet",
    };
}

/// Count a wrong credential, and lock the till when there have been too
/// many.
///
/// A PIN is short, and a short PIN is found by trying every one of
/// them. The till is where that trying happens, so the till is where it
/// stops: after a few wrong guesses it refuses for a while, and a
/// shoulder-surfing guesser gets one attempt rather than five.
fn noteLoginFailure(model: *Model) void {
    model.login_failures += 1;
    if (model.login_failures < model_mod.max_login_failures) return;
    model.login_failures = 0;
    model.login_locked_until = model.now_ms + model_mod.login_lockout_ms;
    model.login_error = "Too many wrong tries - try again in a moment";
    // The guess that triggered the wait is not left in the pad. An
    // operator who comes back after the countdown types a fresh one,
    // rather than pressing Sign in on a secret they did not mean.
    model.credential.clear();
}

/// Turn the cart into an order and write it.
///
/// The order id is the wall clock in milliseconds: a POS writes one
/// order at a time, so the clock is unique enough, and it keeps the
/// order number readable ("1749843210123"). A dedicated sequence would
/// be better - see the roadmap.
fn placeOrder(model: *Model, fx: *Effects, hold: bool) void {
    if (model.cart_len == 0) {
        model.error_text = "The cart is empty";
        return;
    }
    // A sale that is already on its way owns the cart. A second tap
    // would write the same cart twice, and the cashier would see two
    // orders for one table.
    if (model.sale_pending) {
        model.error_text = "The sale is still being saved";
        return;
    }
    const now = fx.wallMs();
    // The sale is an attempt, and the attempt keeps its identity until
    // it lands. The order id is the wall clock, but a clock is not a
    // sequence: two sales in the same millisecond would want the same
    // id, and the second one would land on the first. The floor keeps
    // the ids unique without a round trip.
    //
    // A retry is the SAME sale, so a retry keeps the id and the request
    // key the first attempt had. The database is what decides that two
    // writes are the same sale.
    if (model.cart_attempt_id == 0) {
        model.cart_attempt_id = nextOrderId(model, now);
    }
    const order_id = model.cart_attempt_id;

    // The tax, worked out line by line from each product's own slab,
    // and on what is left of each line after the discount. It is
    // worked out before the order is built, because the order carries
    // it.
    var tax_minor: i64 = 0;
    var discount_minor: i64 = 0;
    for (model.cart[0..model.cart_len], 0..) |line, index| {
        const share = model.cart_discount_share(index);
        discount_minor += share;
        const taxable = line.price_minor * line.qty - share;
        tax_minor += model.tax_on(taxable, model.product_tax_bps(line.product_id));
    }

    var order = domain.Order{
        .id = order_id,
        // The order number is a sequence, and the database assigns it:
        // the number on the ticket is the number that was stored.
        .order_no = "",
        .order_type = model.cart_order_type,
        .status = if (hold) .held else .pending,
        .status_code = @intFromEnum(if (hold) domain.OrderStatus.held else domain.OrderStatus.pending),
        .status_label = (if (hold) domain.OrderStatus.held else domain.OrderStatus.pending).label(),
        .advance_label = (if (hold) domain.OrderStatus.held else domain.OrderStatus.pending).actionLabel(),
        .advanceable = (if (hold) domain.OrderStatus.held else domain.OrderStatus.pending).advanceable(),
        .type_label = model.cart_order_type.label(),
        .dining_table_id = 0,
        .customer_id = 0,
        .employee_id = model.employee_id,
        .subtotal_minor = model.cart_total_minor(),
        .tax_minor = tax_minor,
        .discount_minor = discount_minor,
        // The total is what the customer pays. An exclusive price does
        // not carry its tax, so the tax is added; an inclusive one
        // does, so the tax is a memo and the price is the total.
        .total_minor = model.cart_total_minor() + (if (model.tax_inclusive) 0 else tax_minor) - discount_minor,
        .placed_at = now,
        .notes = "",
    };

    var lines: [model_mod.max_cart_lines]domain.OrderLine = undefined;
    var count: usize = 0;
    for (model.cart[0..model.cart_len]) |line| {
        lines[count] = .{
            // Namespace the line under the order. A plain
            // `order_id + index` can collide with the next order's id
            // when two sales land in adjacent milliseconds, and a
            // remote line id is namespaced the same way under the
            // receiver's negative local order id.
            .id = order_id * 128 + @as(i64, @intCast(count)),
            .order_id = order_id,
            .product_id = line.product_id,
            // The line carries the station that cooks it, so the kitchen
            // board can filter by station without a join.
            .station_id = model.station_of_product(line.product_id),
            .product_name = line.name,
            .qty = line.qty,
            .unit_price_minor = line.price_minor,
            // The rate is a snapshot: a slab that changes tomorrow must
            // not rewrite the bill of yesterday.
            .tax_bps = model.product_tax_bps(line.product_id),
            .notes = "",
        };
        count += 1;
    }

    // The confirmation screen shows this order and the payment is
    // taken against it.
    model.sale_buf.reset();
    model.last_order_id = order.id;
    model.last_order_no_field = model.sale_buf.dupe(order.order_no) orelse "";
    model.last_order_type_field = model.sale_buf.dupe(order.order_type.label()) orelse "";
    model.last_order_total_minor = order.total_minor;
    model.last_order_items_count = 0;
    for (lines[0..count]) |line| model.last_order_items_count += line.qty;
    model.last_order_at = order.placed_at;
    model.payment_check_id = 0;
    model.payment_error = "";
    model.cash_tendered_buf.clear();

    model.busy = true;
    model.sale_pending = true;
    model.cart_hold_pending = hold;
    // The request key: this device's token and the attempt's id. It is
    // what makes a retry the same sale rather than a second one.
    var key_buffer: [64]u8 = undefined;
    const request_key = makeRequestKey(model, order_id, &key_buffer) orelse {
        model.busy = false;
        model.sale_pending = false;
        model.error_text = "Could not make the request key - try again";
        return;
    };
    repos.saveOrder(model, fx, order, lines[0..count], request_key);
}

/// The request key: this device's token, a dash, and the attempt's id.
///
/// It is the name of one sale attempt, and it is what the database
/// compares when a write comes in: a key it has already seen is a
/// retry, and the order that is already there stays.
///
/// The token is the device's namespace. A model without one still makes
/// a key - the attempt's id is in it, and the attempt's id is unique
/// within the device - so a sale is never blocked by a missing token.
fn makeRequestKey(model: *Model, attempt_id: i64, buffer: *[64]u8) ?[]const u8 {
    const token = model.device_token_buf[0..model.device_token_len];
    const written = if (token.len == 0)
        std.fmt.bufPrint(buffer, "{d}", .{attempt_id}) catch return null
    else
        std.fmt.bufPrint(buffer, "{s}-{d}", .{ token, attempt_id }) catch return null;
    return written[0..written.len];
}

/// The next order id for this device.
///
/// The order id is the wall clock, but a clock is not a sequence: two
/// sales in the same millisecond would want the same id, and the
/// second one would land on the first - two tickets, one row, and a
/// cashier's ticket with another cashier's lines. The floor keeps the
/// ids unique without a round trip.
fn nextOrderId(model: *Model, now: i64) i64 {
    const id = @max(now, model.last_issued_order_id + 1);
    model.last_issued_order_id = id;
    return id;
}
