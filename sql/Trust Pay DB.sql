-- schema_full.sql
-- PostgreSQL schema for Taxingor (comprehensive)
-- Requirements: uuid PKs, created_at, updated_at, is_obsolete, config JSONB,
-- login/logout + refresh token, booking seat locking, wallet ledger triggers, payout checks.

-- -- Create custom schema
CREATE SCHEMA IF NOT EXISTS public;


-- -- Set search path
SET search_path TO public;

-- --------------------
-- Extensions
-- --------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS postgis;    -- optional, for geographic points (origin/destination)
-- (If you prefer uuid_generate_v4(), enable "uuid-ossp" instead.)

-- --------------------
-- Utility: auto-update updated_at
-- --------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- --------------------
-- USERS
-- --------------------
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT,
  phone VARCHAR(30) UNIQUE,
  email VARCHAR(255) UNIQUE,
  password_hash TEXT,                 -- salted hashed password (or null when using external auth)
  role VARCHAR(20) NOT NULL CHECK (role IN ('RIDER','DRIVER','ADMIN','SUPPORT')) DEFAULT 'RIDER',
  status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_users_role ON users(role);
CREATE INDEX idx_users_created_at ON users(created_at);

-- --------------------
-- DRIVERS
-- --------------------
CREATE TABLE drivers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kyc_status VARCHAR(20) DEFAULT 'PENDING',     -- PENDING / APPROVED / REJECTED
  enrollment_status VARCHAR(20) DEFAULT 'PENDING', -- PENDING/PAID/ACTIVE
  upfront_paid BOOLEAN DEFAULT FALSE,
  vehicle_profile JSONB DEFAULT '{}'::jsonb,
  license_number VARCHAR(100),
  total_earnings NUMERIC(14,2) DEFAULT 0,       -- cumulative
  available_balance NUMERIC(14,2) DEFAULT 0,    -- withdrawable balance
  reserved_balance NUMERIC(14,2) DEFAULT 0,     -- optional reserve during payout requests
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_drivers_userid ON drivers(user_id);
CREATE INDEX idx_drivers_kyc_status ON drivers(kyc_status);

-- --------------------
-- DRIVER ENROLLMENTS (₹500)
-- --------------------
CREATE TABLE driver_enrollments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  amount NUMERIC(10,2) DEFAULT 500.00,
  gateway_txn TEXT,
  status VARCHAR(20) DEFAULT 'PENDING', -- PENDING, PAID, FAILED
  paid_at TIMESTAMP WITH TIME ZONE,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_driver_enrollments_driver ON driver_enrollments(driver_id);

-- --------------------
-- VEHICLES
-- --------------------
CREATE TABLE vehicles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  make_model TEXT,
  reg_no VARCHAR(50),
  seats INT DEFAULT 4,
  docs JSONB DEFAULT '{}'::jsonb,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_vehicles_driver ON vehicles(driver_id);
CREATE UNIQUE INDEX idx_vehicles_regno ON vehicles(reg_no);

-- --------------------
-- JOURNEY LISTINGS (driver-posted journeys)
-- --------------------
CREATE TABLE journey_listings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  origin_text TEXT,
  destination_text TEXT,
  origin_geo GEOGRAPHY(POINT,4326),        -- PostGIS: point (lon lat)
  destination_geo GEOGRAPHY(POINT,4326),
  departure_ts TIMESTAMP WITH TIME ZONE NOT NULL,
  seats_total INT NOT NULL DEFAULT 1,
  seats_available INT NOT NULL DEFAULT 1,
  price_type VARCHAR(20) DEFAULT 'PER_SEAT', -- PER_SEAT / PER_TRIP
  price_amount NUMERIC(12,2) NOT NULL,
  status VARCHAR(20) DEFAULT 'ACTIVE',     -- ACTIVE/CANCELLED/COMPLETED
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_journey_departure ON journey_listings(departure_ts);
CREATE INDEX idx_journey_driver ON journey_listings(driver_id);
CREATE INDEX idx_journey_seats_avail ON journey_listings(seats_available);
CREATE INDEX idx_journey_price ON journey_listings(price_amount);
CREATE INDEX idx_journey_geo_origin ON journey_listings USING GIST(origin_geo);
CREATE INDEX idx_journey_geo_destination ON journey_listings USING GIST(destination_geo);

-- --------------------
-- BOOKING REQUESTS (initial user request - awaiting driver accept)
-- --------------------
CREATE TABLE booking_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id UUID NOT NULL REFERENCES journey_listings(id) ON DELETE CASCADE,
  rider_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  seats_requested INT NOT NULL DEFAULT 1,
  message TEXT,
  status VARCHAR(20) DEFAULT 'PENDING',  -- PENDING, ACCEPTED, DECLINED, EXPIRED
  expires_at TIMESTAMP WITH TIME ZONE,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_booking_requests_listing_status ON booking_requests(listing_id, status);
CREATE INDEX idx_booking_requests_rider ON booking_requests(rider_id);

-- --------------------
-- BOOKINGS (after driver accepts and booking created)
-- - seats_allocated indicates DB has decreased seats_available for the journey
-- --------------------
CREATE TABLE bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id UUID REFERENCES booking_requests(id) ON DELETE SET NULL,
  listing_id UUID NOT NULL REFERENCES journey_listings(id) ON DELETE CASCADE,
  rider_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  driver_id UUID NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  seats_booked INT NOT NULL DEFAULT 1,
  seats_allocated BOOLEAN DEFAULT FALSE,        -- set true by trigger when seats are deducted
  status VARCHAR(30) DEFAULT 'AWAITING_PAYMENT', -- AWAITING_PAYMENT / CONFIRMED / CANCELLED / COMPLETED / NO_SHOW
  total_amount NUMERIC(12,2) NOT NULL,
  driver_price_snapshot NUMERIC(12,2),
  platform_fee NUMERIC(12,2) DEFAULT 0,
  payment_due_by TIMESTAMP WITH TIME ZONE,    -- TTL for payment capture
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_bookings_status ON bookings(status);
CREATE INDEX idx_bookings_listing ON bookings(listing_id);
CREATE INDEX idx_bookings_rider ON bookings(rider_id);
CREATE INDEX idx_bookings_driver ON bookings(driver_id);

-- --------------------
-- PAYMENTS
-- --------------------
CREATE TABLE payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  gateway VARCHAR(50),
  method VARCHAR(50),   -- UPI/CARD/NETBANKING
  amount NUMERIC(12,2) NOT NULL,
  currency VARCHAR(10) DEFAULT 'INR',
  status VARCHAR(20) DEFAULT 'INITIATED', -- INITIATED / CAPTURED / FAILED / REFUNDED
  provider_ref TEXT,
  provider_payload JSONB,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_payments_booking ON payments(booking_id);
CREATE INDEX idx_payments_status ON payments(status);

-- --------------------
-- WALLET ENTRIES (ledger). Adjusts drivers' balances via trigger
-- --------------------
CREATE TABLE wallet_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID REFERENCES drivers(id) ON DELETE CASCADE,  -- nullable for platform credits
  booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
  type VARCHAR(10) NOT NULL CHECK (type IN ('CREDIT','DEBIT')),
  amount NUMERIC(12,2) NOT NULL,
  balance_after NUMERIC(14,2),    -- optional snapshot after applying this entry
  reason_code VARCHAR(100),       -- BOOKING,EARNING,REFUND,PAYOUT,ENROLLMENT_FEE,ADMIN_ADJ, etc.
  correlation_id UUID,            -- link to external txn
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_wallet_driver_created ON wallet_entries(driver_id, created_at);
CREATE INDEX idx_wallet_reason ON wallet_entries(reason_code);

-- --------------------
-- PAYOUTS
-- --------------------
CREATE TABLE payouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  amount NUMERIC(12,2) NOT NULL,
  provider VARCHAR(100),   -- RazorpayX / Cashfree etc.
  provider_ref TEXT,
  status VARCHAR(20) DEFAULT 'PENDING', -- PENDING / PROCESSING / PAID / FAILED
  requested_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  processed_at TIMESTAMP WITH TIME ZONE,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_payouts_driver ON payouts(driver_id);
CREATE INDEX idx_payouts_status ON payouts(status);

-- --------------------
-- CANCELLATIONS / REFUNDS
-- --------------------
CREATE TABLE cancellations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  actor VARCHAR(20) NOT NULL CHECK (actor IN ('RIDER','DRIVER','SYSTEM','ADMIN')),
  policy_code VARCHAR(50),
  refund_amount NUMERIC(12,2) DEFAULT 0,
  notes TEXT,
  processed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX idx_cancellations_booking ON cancellations(booking_id);

-- --------------------
-- AUDIT LOGS
-- --------------------
CREATE TABLE audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  object_type VARCHAR(100),   -- table or domain object
  object_id UUID,
  action VARCHAR(100),
  payload JSONB,
  ip VARCHAR(100),
  user_agent TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX idx_audit_object ON audit_logs(object_type, object_id);

-- --------------------
-- NOTIFICATIONS (queue)
-- --------------------
CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  to_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  type VARCHAR(50),         -- EMAIL/SMS/PUSH/INAPP
  channel VARCHAR(50),
  payload JSONB,
  status VARCHAR(20) DEFAULT 'PENDING', -- PENDING/SENT/FAILED
  attempts INT DEFAULT 0,
  scheduled_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  sent_at TIMESTAMP WITH TIME ZONE,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX idx_notifications_status ON notifications(status);
CREATE INDEX idx_notifications_user ON notifications(to_user_id);

-- --------------------
-- FRAUD FLAGS
-- --------------------
CREATE TABLE fraud_flags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
  reason TEXT,
  severity INT DEFAULT 1,
  resolved BOOLEAN DEFAULT FALSE,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX idx_fraud_user ON fraud_flags(user_id);

-- --------------------
-- RATE LIMITS (simple)
-- --------------------
CREATE TABLE rate_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT NOT NULL,    -- e.g. 'login:ip:1.2.3.4' or 'otp:phone:...'
  count INT DEFAULT 0,
  reset_at TIMESTAMP WITH TIME ZONE,
  config JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_rate_limits_key ON rate_limits(key);

-- --------------------
-- AUTH SESSIONS (login/logout)
-- --------------------
CREATE TABLE auth_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_info TEXT,
  ip VARCHAR(100),
  user_agent TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  last_activity_at TIMESTAMP WITH TIME ZONE,
  expires_at TIMESTAMP WITH TIME ZONE,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX idx_sessions_user ON auth_sessions(user_id);
CREATE INDEX idx_sessions_active ON auth_sessions(is_active);

-- --------------------
-- REFRESH TOKENS (rotate, revoke)
-- --------------------
CREATE TABLE refresh_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id UUID REFERENCES auth_sessions(id) ON DELETE CASCADE,
  token TEXT NOT NULL,         -- store hashed token ideally; here for demo
  token_hash TEXT,             -- recommended: store hashed token (e.g. SHA-256)
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  last_used_at TIMESTAMP WITH TIME ZONE,
  expires_at TIMESTAMP WITH TIME ZONE,
  revoked BOOLEAN DEFAULT FALSE,
  replaced_by UUID REFERENCES refresh_tokens(id) ON DELETE SET NULL,
  config JSONB DEFAULT '{}'::jsonb,
  is_obsolete BOOLEAN DEFAULT FALSE,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX idx_refresh_user ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_session ON refresh_tokens(session_id);
CREATE INDEX idx_refresh_tokenhash ON refresh_tokens(token_hash);

-- --------------------
-- OTP CODES (optional for phone login)
-- --------------------
CREATE TABLE otp_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone VARCHAR(30),
  code TEXT, -- store hashed in prod
  expires_at TIMESTAMP WITH TIME ZONE,
  used BOOLEAN DEFAULT FALSE,
  attempts INT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX idx_otp_phone ON otp_codes(phone);

-- --------------------
-- LOGIN ATTEMPTS (tracking to throttle / lock)
-- --------------------
CREATE TABLE login_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  ip VARCHAR(100),
  user_agent TEXT,
  success BOOLEAN,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX idx_login_attempts_user ON login_attempts(user_id);

-- --------------------
-- TRIGGERS: Booking seat management
--  - BEFORE INSERT bookings: verify and decrement seats_available (locking)
--  - BEFORE UPDATE bookings: when status becomes CANCELLED/REJECTED/EXPIRED, restore seats
-- --------------------
CREATE OR REPLACE FUNCTION booking_before_insert_fn()
RETURNS TRIGGER AS $$
DECLARE
  avail INT;
BEGIN
  -- lock journey row
  SELECT seats_available INTO avail FROM journey_listings WHERE id = NEW.listing_id FOR UPDATE;
  IF avail IS NULL THEN
    RAISE EXCEPTION 'journey_listings not found: %', NEW.listing_id;
  END IF;

  IF NEW.seats_booked > avail THEN
    RAISE EXCEPTION 'Not enough seats: requested %, available %', NEW.seats_booked, avail;
  END IF;

  UPDATE journey_listings
    SET seats_available = seats_available - NEW.seats_booked,
        updated_at = NOW()
  WHERE id = NEW.listing_id;

  NEW.seats_allocated = TRUE;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_booking_before_insert
BEFORE INSERT ON bookings
FOR EACH ROW EXECUTE FUNCTION booking_before_insert_fn();

CREATE OR REPLACE FUNCTION booking_before_update_fn()
RETURNS TRIGGER AS $$
BEGIN
  -- If previously seats were allocated and now booking is cancelled-like, restore seats
  IF (OLD.seats_allocated = TRUE)
     AND (NEW.status IN ('CANCELLED','REJECTED','EXPIRED','NO_SHOW'))
     AND (OLD.status NOT IN ('CANCELLED','REJECTED','EXPIRED','NO_SHOW')) THEN

    UPDATE journey_listings
      SET seats_available = seats_available + OLD.seats_booked,
          updated_at = NOW()
      WHERE id = OLD.listing_id;

    NEW.seats_allocated = FALSE;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_booking_before_update
BEFORE UPDATE ON bookings
FOR EACH ROW EXECUTE FUNCTION booking_before_update_fn();

-- --------------------
-- TRIGGER: wallet_entries -> update driver's totals & available balance
-- --------------------
CREATE OR REPLACE FUNCTION wallet_entries_after_insert_fn()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.driver_id IS NOT NULL THEN
    IF NEW.type = 'CREDIT' THEN
      UPDATE drivers
      SET total_earnings = COALESCE(total_earnings,0) + NEW.amount,
          available_balance = COALESCE(available_balance,0) + NEW.amount,
          updated_at = NOW()
      WHERE id = NEW.driver_id;
    ELSIF NEW.type = 'DEBIT' THEN
      UPDATE drivers
      SET available_balance = COALESCE(available_balance,0) - NEW.amount,
          updated_at = NOW()
      WHERE id = NEW.driver_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_wallet_entries_after_insert
AFTER INSERT ON wallet_entries
FOR EACH ROW EXECUTE FUNCTION wallet_entries_after_insert_fn();

-- --------------------
-- TRIGGER: payouts -> precheck (total_earnings >= 500, available_balance sufficient)
-- --------------------
CREATE OR REPLACE FUNCTION payouts_before_insert_fn()
RETURNS TRIGGER AS $$
DECLARE
  tot NUMERIC;
  avail NUMERIC;
BEGIN
  SELECT total_earnings, available_balance INTO tot, avail
    FROM drivers
    WHERE id = NEW.driver_id FOR UPDATE;

  IF tot IS NULL THEN
    RAISE EXCEPTION 'driver not found: %', NEW.driver_id;
  END IF;

  IF tot < 500 THEN
    RAISE EXCEPTION 'driver total_earnings % < minimum allowed for payout (500)', tot;
  END IF;

  IF avail < NEW.amount THEN
    RAISE EXCEPTION 'insufficient available balance: %', avail;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payouts_before_insert
BEFORE INSERT ON payouts
FOR EACH ROW EXECUTE FUNCTION payouts_before_insert_fn();

-- --------------------
-- TRIGGER: auth_sessions -> when session is deactivated, revoke refresh tokens for that session
-- --------------------
CREATE OR REPLACE FUNCTION revoke_tokens_on_session_inactive_fn()
RETURNS TRIGGER AS $$
BEGIN
  IF (OLD.is_active = TRUE) AND (NEW.is_active = FALSE) THEN
    UPDATE refresh_tokens
      SET revoked = TRUE, updated_at = NOW()
      WHERE session_id = OLD.id AND revoked = FALSE;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sessions_after_update
AFTER UPDATE ON auth_sessions
FOR EACH ROW EXECUTE FUNCTION revoke_tokens_on_session_inactive_fn();

-- --------------------
-- Apply set_updated_at trigger to all tables that require it
-- --------------------
-- list of tables requiring updated_at auto update
DO $$
BEGIN
  PERFORM 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'users';
  -- Create triggers for each table explicitly:
  EXECUTE 'CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_drivers_updated BEFORE UPDATE ON drivers FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_driver_enrollments_updated BEFORE UPDATE ON driver_enrollments FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_vehicles_updated BEFORE UPDATE ON vehicles FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_journey_listings_updated BEFORE UPDATE ON journey_listings FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_booking_requests_updated BEFORE UPDATE ON booking_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_bookings_updated BEFORE UPDATE ON bookings FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_payments_updated BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_wallet_entries_updated BEFORE UPDATE ON wallet_entries FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_payouts_updated BEFORE UPDATE ON payouts FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_cancellations_updated BEFORE UPDATE ON cancellations FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_notifications_updated BEFORE UPDATE ON notifications FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_fraud_flags_updated BEFORE UPDATE ON fraud_flags FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_rate_limits_updated BEFORE UPDATE ON rate_limits FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_auth_sessions_updated BEFORE UPDATE ON auth_sessions FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_refresh_tokens_updated BEFORE UPDATE ON refresh_tokens FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_payments_updated2 BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
  EXECUTE 'CREATE TRIGGER trg_withdrawals_updated BEFORE UPDATE ON payouts FOR EACH ROW EXECUTE FUNCTION set_updated_at();';
END;
$$ LANGUAGE plpgsql;

-- --------------------
-- Helpful partial indexes / constraints
-- --------------------
-- Only allow positive seats
ALTER TABLE journey_listings ADD CONSTRAINT chk_seats_positive CHECK (seats_total >= 0 AND seats_available >= 0);
ALTER TABLE bookings ADD CONSTRAINT chk_seats_booked_positive CHECK (seats_booked >= 0);

-- --------------------
-- Final Notes:
--  - This schema enforces basic DB-level guards (seat allocation, payout pre-checks, ledger updates).
--  - Application layer MUST still handle complex business flows: idempotency keys, payment webhook verification,
--    retries, outbox pattern for events, background jobs to release locks on payment timeout, and more.
--  - In production, store refresh token hashes, not raw tokens.
--  - Add additional indices based on your query patterns (e.g., frequent searches by origin/destination/time).
-- --------------------

