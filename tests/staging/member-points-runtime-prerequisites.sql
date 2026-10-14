-- Minimal disposable PostgreSQL contract fixture for applying 477000 after Member Core.
-- Behavioral checkout coverage uses the full Quena staging harness when available.
ALTER TABLE public.outlets ADD COLUMN is_active boolean NOT NULL DEFAULT true;
ALTER TABLE public.outlets ADD COLUMN customer_display_name text;
ALTER TABLE public.outlets ADD COLUMN address text, ADD COLUMN city text, ADD COLUMN province text, ADD COLUMN postal_code text, ADD COLUMN phone text, ADD COLUMN whatsapp text;
CREATE TABLE public.outlet_settings_events(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),outlet_id uuid NOT NULL,actor_id uuid NOT NULL,event_type text NOT NULL CHECK(event_type='OUTLET_SETTINGS_UPDATED'),changed_fields text[] NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.outlet_pos_settings(outlet_id uuid PRIMARY KEY,receipt_show_address boolean DEFAULT true,receipt_show_phone boolean DEFAULT true,receipt_footer_note text);
CREATE TYPE public.pos_cart_event_type AS ENUM('CREATED','ITEM_ADDED','ITEM_QUANTITY_CHANGED','ITEM_REMOVED','PRICE_ACKNOWLEDGED','PARKED','RESUMED','CANCELLED');
CREATE TABLE public.pos_cart_mutation_requests(request_id uuid PRIMARY KEY,actor_id uuid NOT NULL,outlet_id uuid NOT NULL,operation_key text NOT NULL CHECK(operation_key IN('CREATE','ADD_ITEM','SET_QUANTITY','ACK_PRICE','PARK','RESUME','CANCEL')),target_key text NOT NULL,payload_hash text NOT NULL,result jsonb,completed_at timestamptz);
CREATE TABLE public.pos_cart_events(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),cart_id uuid NOT NULL,outlet_id uuid NOT NULL,event_type public.pos_cart_event_type NOT NULL,actor_id uuid NOT NULL,request_id uuid NOT NULL UNIQUE,revision bigint NOT NULL,event_data jsonb NOT NULL DEFAULT '{}');
CREATE TABLE public.pos_cart_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),cart_id uuid NOT NULL,outlet_id uuid NOT NULL,product_id uuid NOT NULL,quantity numeric NOT NULL,observed_unit_price numeric NOT NULL);
CREATE TYPE public.pos_sale_payment_method AS ENUM('CASH','QRIS','CARD','E_WALLET');
CREATE TYPE public.inventory_cost_authority_status AS ENUM('INACTIVE','WAC_ACTIVE');
ALTER TABLE public.sales ADD COLUMN subtotal numeric(32,2) NOT NULL DEFAULT 0;
ALTER TABLE public.sales ADD COLUMN discount_total numeric(32,2) NOT NULL DEFAULT 0 CONSTRAINT sales_discount_total_check CHECK(discount_total=0);
ALTER TABLE public.sales ADD COLUMN cashier_id uuid, ADD COLUMN completed_by uuid, ADD COLUMN checkout_request_id uuid, ADD COLUMN sale_number text, ADD COLUMN checkout_request_id_dummy uuid;
CREATE TABLE public.pos_checkout_requests(request_id uuid PRIMARY KEY,actor_id uuid,outlet_id uuid,cart_id uuid,expected_cart_revision bigint,payment_payload_hash text,state text,sale_id uuid,result jsonb,completed_at timestamptz);
CREATE TABLE public.profiles(id uuid PRIMARY KEY,full_name text);
CREATE TABLE public.products(id uuid PRIMARY KEY,name text,sku text,unit_label text);
CREATE TABLE public.stock_balance_projection(outlet_id uuid,product_id uuid,effective_quantity numeric,authority_period_id uuid);
CREATE TABLE public.product_selling_prices(outlet_id uuid,product_id uuid,amount numeric);
CREATE TABLE public.product_selling_price_history(id uuid,effective_at timestamptz,outlet_id uuid,product_id uuid,amount numeric);
CREATE TABLE public.inventory_cost_projections(outlet_id uuid,product_id uuid);
CREATE TABLE public.inventory_cost_source_layer_balances(outlet_id uuid,product_id uuid,layer_id uuid);
CREATE TABLE public.inventory_costing_outlet_authority(outlet_id uuid,status public.inventory_cost_authority_status);
CREATE TABLE public.stock_operation_requests(request_id uuid,actor_id uuid,operation_key text,target_key text,request_payload jsonb,payload_hash text,state text,result jsonb,completed_at timestamptz);
CREATE TABLE public.sale_payments(sale_id uuid,outlet_id uuid,method public.pos_sale_payment_method,applied_amount numeric,received_amount numeric,change_amount numeric,reference_text text,recorded_by uuid,recorded_at timestamptz DEFAULT now());
ALTER TABLE public.stock_authority_periods ADD COLUMN id uuid DEFAULT gen_random_uuid();
ALTER TABLE public.stock_authority_periods ADD COLUMN authority_period_id uuid;
ALTER TABLE public.stock_authority_periods ADD COLUMN outlet_id_dummy uuid;
CREATE OR REPLACE FUNCTION public.outlet_settings_current_id() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT outlet_id FROM public.stock_authority_periods WHERE ended_at IS NULL LIMIT 1 $$;
CREATE OR REPLACE FUNCTION public.pos_cart_request_begin(p_request uuid,p_actor uuid,p_outlet uuid,p_operation text,p_target text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE q public.pos_cart_mutation_requests%ROWTYPE; h text;
BEGIN
  h:=md5(p_payload::text);
  INSERT INTO public.pos_cart_mutation_requests(request_id,actor_id,outlet_id,operation_key,target_key,payload_hash)
    VALUES(p_request,p_actor,p_outlet,p_operation,p_target,h) ON CONFLICT(request_id) DO NOTHING;
  SELECT * INTO q FROM public.pos_cart_mutation_requests WHERE request_id=p_request FOR UPDATE;
  IF q.actor_id<>p_actor OR q.outlet_id<>p_outlet OR q.operation_key<>p_operation OR q.target_key<>p_target OR q.payload_hash<>h THEN
    RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='POS_CART_REQUEST_REUSED'; END IF;
  RETURN q.result;
END $$;
CREATE OR REPLACE FUNCTION public.pos_cart_set_result(p_request uuid,p_result jsonb) RETURNS void LANGUAGE sql AS $$
  UPDATE public.pos_cart_mutation_requests SET result=p_result,completed_at=now() WHERE request_id=p_request AND result IS NULL
$$;
CREATE OR REPLACE FUNCTION public.stock_apply_balance_delta(uuid,uuid,numeric) RETURNS TABLE(balance_before numeric,balance_after numeric,new_balance_version bigint) LANGUAGE sql AS $$ SELECT 0::numeric,0::numeric,1::bigint $$;
CREATE OR REPLACE FUNCTION public.inventory_cost_apply_pos_sale(uuid,uuid,uuid,uuid,uuid) RETURNS bigint LANGUAGE sql AS $$ SELECT 0::bigint $$;
