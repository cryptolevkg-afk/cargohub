-- ============================================================================
-- CargoHub — схема базы данных (PostgreSQL 14+)
-- Покрывает модули: Карго-консолидация, Биржа грузоперевозок, сквозные сервисы
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ---------------------------------------------------------------------------
-- 1. ПОЛЬЗОВАТЕЛИ И РОЛИ
-- ---------------------------------------------------------------------------

CREATE TYPE user_role AS ENUM (
  'client', 'cargo_operator', 'warehouse_staff_origin', 'warehouse_staff_dest',
  'courier', 'shipper', 'carrier', 'dispatcher', 'support', 'admin'
);

CREATE TYPE kyc_status AS ENUM ('none', 'pending', 'verified', 'rejected');

CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  phone         VARCHAR(20) UNIQUE NOT NULL,
  email         VARCHAR(255) UNIQUE,
  password_hash TEXT NOT NULL,
  full_name     VARCHAR(255) NOT NULL,
  company_name  VARCHAR(255),               -- для юр.лиц (карго-операторы, перевозчики-компании)
  locale        VARCHAR(5) DEFAULT 'ru',
  kyc_status    kyc_status DEFAULT 'none',
  kyc_doc_url   TEXT,
  rating        NUMERIC(2,1) DEFAULT 5.0,
  is_active     BOOLEAN DEFAULT TRUE,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

-- один пользователь может иметь несколько ролей одновременно
CREATE TABLE user_roles (
  user_id  UUID REFERENCES users(id) ON DELETE CASCADE,
  role     user_role NOT NULL,
  PRIMARY KEY (user_id, role)
);

CREATE INDEX idx_user_roles_role ON user_roles(role);

-- ---------------------------------------------------------------------------
-- 2. МОДУЛЬ «КАРГО»: склады, посылки, консолидация, тарифы
-- ---------------------------------------------------------------------------

CREATE TABLE warehouses (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  country      VARCHAR(100) NOT NULL,        -- 'Китай', 'Турция', 'Кыргызстан' ...
  city         VARCHAR(100) NOT NULL,
  code         VARCHAR(20) UNIQUE NOT NULL,  -- 'GZ', 'IST', 'FRU'
  address      TEXT NOT NULL,
  is_origin    BOOLEAN DEFAULT TRUE,         -- склад-источник или склад назначения
  is_active    BOOLEAN DEFAULT TRUE
);

-- персональный адрес (ячейка) клиента на конкретном складе-источнике
CREATE TABLE client_warehouse_cells (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  client_id     UUID REFERENCES users(id) ON DELETE CASCADE,
  warehouse_id  UUID REFERENCES warehouses(id),
  cell_code     VARCHAR(30) NOT NULL,        -- 'GZ-1042'
  UNIQUE (client_id, warehouse_id)
);

CREATE TYPE package_status AS ENUM (
  'awaiting_arrival', 'at_warehouse', 'consolidating', 'in_transit',
  'customs', 'at_destination_warehouse', 'out_for_delivery', 'delivered', 'issue'
);

CREATE TABLE packages (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  client_id        UUID REFERENCES users(id),
  warehouse_id     UUID REFERENCES warehouses(id),
  track_number     VARCHAR(100) NOT NULL,
  shop_name        VARCHAR(255),
  category         VARCHAR(100),             -- влияет на тариф/ограничения (обувь, электроника, аккумуляторы...)
  declared_value   NUMERIC(10,2),
  currency         VARCHAR(3) DEFAULT 'USD',
  weight_kg        NUMERIC(8,3),
  length_cm        NUMERIC(6,1),
  width_cm         NUMERIC(6,1),
  height_cm        NUMERIC(6,1),
  volumetric_weight_kg NUMERIC(8,3) GENERATED ALWAYS AS
    (length_cm * width_cm * height_cm / 6000.0) STORED,
  status           package_status DEFAULT 'awaiting_arrival',
  photo_urls       TEXT[],
  received_at      TIMESTAMPTZ,
  created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_packages_client ON packages(client_id);
CREATE INDEX idx_packages_status ON packages(status);
CREATE INDEX idx_packages_track ON packages(track_number);

-- сборный груз (консолидация нескольких посылок в одну отправку)
CREATE TYPE shipment_status AS ENUM (
  'forming', 'consolidated', 'in_transit', 'customs', 'at_destination', 'delivered'
);

CREATE TABLE shipments (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  client_id      UUID REFERENCES users(id),
  status         shipment_status DEFAULT 'forming',
  delivery_method VARCHAR(20),               -- 'air' | 'road' | 'rail'
  delivery_speed  VARCHAR(20),               -- 'express' | 'economy'
  total_weight_kg NUMERIC(8,3),
  total_cost      NUMERIC(10,2),
  currency        VARCHAR(3) DEFAULT 'KGS',
  destination_warehouse_id UUID REFERENCES warehouses(id),
  freight_request_id UUID,                   -- опционально: если магистральная перевозка ушла через биржу
  created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE shipment_packages (
  shipment_id  UUID REFERENCES shipments(id) ON DELETE CASCADE,
  package_id   UUID REFERENCES packages(id) ON DELETE CASCADE,
  PRIMARY KEY (shipment_id, package_id)
);

CREATE TABLE tariffs (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  warehouse_id      UUID REFERENCES warehouses(id),
  destination_country VARCHAR(100) NOT NULL,
  delivery_method   VARCHAR(20) NOT NULL,
  delivery_speed    VARCHAR(20) NOT NULL,
  price_per_kg      NUMERIC(8,2),
  min_price         NUMERIC(8,2),
  currency          VARCHAR(3) DEFAULT 'KGS',
  is_active         BOOLEAN DEFAULT TRUE
);

CREATE TABLE prohibited_items (
  id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  keyword   VARCHAR(255) NOT NULL,
  category  VARCHAR(100),
  country   VARCHAR(100),                    -- ограничение действует для конкретной страны назначения
  severity  VARCHAR(20) DEFAULT 'blocked'     -- 'blocked' | 'requires_declaration'
);

CREATE TABLE customs_declarations (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  shipment_id    UUID REFERENCES shipments(id),
  invoice_number VARCHAR(50) UNIQUE,
  status         VARCHAR(30) DEFAULT 'pending', -- pending | submitted | cleared | held
  total_declared_value NUMERIC(10,2),
  document_url   TEXT,
  submitted_at   TIMESTAMPTZ,
  cleared_at     TIMESTAMPTZ
);

CREATE TABLE insurance_policies (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  shipment_id  UUID REFERENCES shipments(id),
  insured_value NUMERIC(10,2),
  premium      NUMERIC(8,2),
  status       VARCHAR(20) DEFAULT 'active',  -- active | claimed | closed
  created_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE claims (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  package_id   UUID REFERENCES packages(id),
  client_id    UUID REFERENCES users(id),
  reason       VARCHAR(50),                    -- damaged | lost | wrong_item
  description  TEXT,
  photo_urls   TEXT[],
  status       VARCHAR(20) DEFAULT 'review',    -- review | approved | rejected | compensated
  compensation NUMERIC(10,2),
  created_at   TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 3. МОДУЛЬ «БИРЖА ГРУЗОПЕРЕВОЗОК»
-- ---------------------------------------------------------------------------

CREATE TYPE freight_status AS ENUM ('open', 'assigned', 'in_progress', 'delivered', 'cancelled');

CREATE TABLE freight_requests (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  shipper_id     UUID REFERENCES users(id),
  from_city      VARCHAR(100) NOT NULL,
  to_city        VARCHAR(100) NOT NULL,
  cargo_type     VARCHAR(255),
  weight_tons    NUMERIC(8,2),
  volume_cbm     NUMERIC(8,2),
  vehicle_type   VARCHAR(100),                 -- 'Тент 20т', 'Реф 5т' ...
  budget         NUMERIC(10,2),
  currency       VARCHAR(3) DEFAULT 'KGS',
  pickup_date    DATE,
  status         freight_status DEFAULT 'open',
  assigned_carrier_id UUID REFERENCES users(id),
  assigned_vehicle_id UUID,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_freight_status ON freight_requests(status);
CREATE INDEX idx_freight_route ON freight_requests(from_city, to_city);

CREATE TABLE freight_bids (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  request_id   UUID REFERENCES freight_requests(id) ON DELETE CASCADE,
  carrier_id   UUID REFERENCES users(id),
  price        NUMERIC(10,2) NOT NULL,
  message      TEXT,
  status       VARCHAR(20) DEFAULT 'pending',  -- pending | accepted | rejected
  created_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE vehicles (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  carrier_id     UUID REFERENCES users(id),
  plate_number   VARCHAR(20) NOT NULL,
  vehicle_type   VARCHAR(100),
  capacity_kg    NUMERIC(8,1),
  insurance_doc_url TEXT,
  tech_passport_url TEXT,
  is_verified    BOOLEAN DEFAULT FALSE
);

CREATE TYPE trip_stage AS ENUM ('loading', 'in_transit', 'unloading', 'delivered');

CREATE TABLE trips (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  request_id     UUID REFERENCES freight_requests(id),
  carrier_id     UUID REFERENCES users(id),
  vehicle_id     UUID REFERENCES vehicles(id),
  stage          trip_stage DEFAULT 'loading',
  gps_lat        NUMERIC(9,6),
  gps_lng        NUMERIC(9,6),
  gps_updated_at TIMESTAMPTZ,
  pod_photo_url  TEXT,                          -- proof of delivery
  created_at     TIMESTAMPTZ DEFAULT now(),
  updated_at     TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 4. СКВОЗНЫЕ МОДУЛИ: кошелёк, документы, чат, отзывы, поддержка
-- ---------------------------------------------------------------------------

CREATE TABLE wallets (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  balance    NUMERIC(12,2) DEFAULT 0,
  currency   VARCHAR(3) DEFAULT 'KGS'
);

CREATE TABLE transactions (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  wallet_id     UUID REFERENCES wallets(id),
  type          VARCHAR(20) NOT NULL,          -- topup | payment | refund | payout | escrow_hold | escrow_release
  amount        NUMERIC(12,2) NOT NULL,        -- отрицательное значение = списание
  related_type  VARCHAR(30),                   -- 'shipment' | 'freight_request' | ...
  related_id    UUID,
  description   TEXT,
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE documents (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_type  VARCHAR(30) NOT NULL,             -- 'shipment' | 'freight_request' | 'user'
  owner_id    UUID NOT NULL,
  doc_type    VARCHAR(50) NOT NULL,             -- 'invoice' | 'ttn' | 'act' | 'declaration' | 'contract'
  file_url    TEXT NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE chats (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  participant_a  UUID REFERENCES users(id),
  participant_b  UUID REFERENCES users(id),
  related_type   VARCHAR(30),
  related_id     UUID,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE messages (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  chat_id    UUID REFERENCES chats(id) ON DELETE CASCADE,
  sender_id  UUID REFERENCES users(id),
  text       TEXT,
  attachment_url TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE reviews (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  from_user_id  UUID REFERENCES users(id),
  to_user_id    UUID REFERENCES users(id),
  related_type  VARCHAR(30),
  related_id    UUID,
  rating        SMALLINT CHECK (rating BETWEEN 1 AND 5),
  comment       TEXT,
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE support_tickets (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID REFERENCES users(id),
  subject     VARCHAR(255),
  status      VARCHAR(20) DEFAULT 'open',       -- open | in_progress | resolved | closed
  priority    VARCHAR(10) DEFAULT 'normal',
  related_type VARCHAR(30),
  related_id  UUID,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE ticket_messages (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ticket_id  UUID REFERENCES support_tickets(id) ON DELETE CASCADE,
  sender_id  UUID REFERENCES users(id),
  text       TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 5. АДМИНИСТРИРОВАНИЕ / АУДИТ
-- ---------------------------------------------------------------------------

CREATE TABLE audit_log (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id    UUID REFERENCES users(id),
  action      VARCHAR(100) NOT NULL,
  entity_type VARCHAR(50),
  entity_id   UUID,
  meta        JSONB,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Стартовые справочные данные
-- ---------------------------------------------------------------------------

INSERT INTO warehouses (country, city, code, address, is_origin) VALUES
  ('Китай', 'Гуанчжоу', 'GZ', 'Guangzhou, Baiyun District, warehouse 12', TRUE),
  ('Турция', 'Стамбул', 'IST', 'Istanbul, Bagcilar, warehouse 4', TRUE),
  ('Кыргызстан', 'Бишкек', 'FRU', 'Бишкек, ул. Складская 8', FALSE);
