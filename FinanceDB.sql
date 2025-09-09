create database personal_finance_db;
use personal_finance_db;

-- =============================
-- 2) TABLES (normalized)
-- =============================

-- 2.1 users
create table users (
  user_id    int primary key auto_increment,
  full_name  varchar(120) not null,
  email      varchar(120) unique,
  created_at timestamp not null default current_timestamp
);

-- 2.2 accounts (cash/bank/card/wallet)
create table accounts (
  account_id   int primary key auto_increment,
  user_id      int not null,
  account_name varchar(100) not null,
  account_type enum('cash','bank','card','wallet') not null,
  currency     char(3) not null default 'INR',
  created_at   timestamp not null default current_timestamp,
  foreign key (user_id) references users(user_id)
);

-- 2.3 categories (scoped per user)
create table categories (
  category_id   int primary key auto_increment,
  user_id       int not null,
  category_name varchar(100) not null,
  category_type enum('income','expense') not null,
  is_active     tinyint not null default 1,
  created_at    timestamp not null default current_timestamp,
  unique key uq_user_cat (user_id, category_name, category_type),
  foreign key (user_id) references users(user_id)
);

-- 2.4 transactions (income/expense)
create table transactions (
  txn_id      int primary key auto_increment,
  user_id     int not null,
  account_id  int not null,
  category_id int not null,
  txn_type    enum('income','expense') not null,
  amount      decimal(12,2) not null check (amount > 0),
  txn_date    date not null,
  merchant    varchar(120),
  note        varchar(255),
  created_at  timestamp not null default current_timestamp,
  foreign key (user_id) references users(user_id),
  foreign key (account_id) references accounts(account_id),
  foreign key (category_id) references categories(category_id)
);

-- 2.5 budgets (monthly per category)
create table budgets (
  budget_id   int primary key auto_increment,
  user_id     int not null,
  category_id int not null,
  month_year  date not null, -- store as first day of month (e.g., 2025-08-01)
  amount      decimal(12,2) not null check (amount >= 0),
  created_at  timestamp not null default current_timestamp,
  unique key uq_budget (user_id, category_id, month_year),
  foreign key (user_id) references users(user_id),
  foreign key (category_id) references categories(category_id)
);

-- =============================
-- 3) INDEXES (performance)
-- =============================
create index idx_txn_user_date on transactions(user_id, txn_date);
create index idx_txn_category on transactions(category_id);
create index idx_txn_account on transactions(account_id);

-- =============================
-- 4) VIEWS (reports)
-- =============================

-- 4.1 account balances (computed, no denormalized balance column)
create or replace view v_account_balance as
select 
  a.account_id,
  a.account_name,
  a.account_type,
  a.user_id,
  coalesce(sum(case when t.txn_type = 'income' then t.amount else -t.amount end), 0) as balance
from accounts a
left join transactions t on t.account_id = a.account_id
group by a.account_id, a.account_name, a.account_type, a.user_id;

-- 4.2 monthly summary per user (income, expense, net)
create or replace view v_monthly_summary as
select
  t.user_id,
  date_format(t.txn_date, '%Y-%m-01') as month_start,
  sum(case when t.txn_type = 'income' then t.amount else 0 end) as total_income,
  sum(case when t.txn_type = 'expense' then t.amount else 0 end) as total_expense,
  sum(case when t.txn_type = 'income' then t.amount else -t.amount end) as net_amount
from transactions t
group by t.user_id, date_format(t.txn_date, '%Y-%m-01');

-- 4.3 expense by category per month (top spending areas)
create or replace view v_category_spend_month as
select
  t.user_id,
  date_format(t.txn_date, '%Y-%m-01') as month_start,
  c.category_name,
  sum(case when t.txn_type = 'expense' then t.amount else 0 end) as spend
from transactions t
join categories c on c.category_id = t.category_id
where t.txn_type = 'expense'
group by t.user_id, date_format(t.txn_date, '%Y-%m-01'), c.category_name;

-- 4.4 budget status per month/category
create or replace view v_budget_status as
with spend as (
  select 
    t.user_id,
    t.category_id,
    date_format(t.txn_date, '%Y-%m-01') as month_start,
    sum(case when t.txn_type = 'expense' then t.amount else 0 end) as spent
  from transactions t
  group by t.user_id, t.category_id, date_format(t.txn_date, '%Y-%m-01')
)
select 
  b.user_id,
  b.category_id,
  c.category_name,
  b.month_year as month_start,
  b.amount as budget,
  coalesce(s.spent, 0) as spent,
  (coalesce(s.spent, 0) - b.amount) as variance,
  (coalesce(s.spent, 0) > b.amount) as over_budget
from budgets b
join categories c on c.category_id = b.category_id
left join spend s on s.user_id = b.user_id and s.category_id = b.category_id and s.month_start = date_format(b.month_year, '%Y-%m-01');

-- =============================
-- 5) TRIGGERS (data integrity)
-- =============================
delimiter $$

-- 5.1 ensure transaction type matches category type
create trigger trg_txn_check_category_bi
before insert on transactions
for each row
begin
  declare v_cat_type enum('income','expense');
  select category_type into v_cat_type from categories where category_id = new.category_id;
  if v_cat_type is null then
    signal sqlstate '45000' set message_text = 'invalid category_id';
  end if;
  if new.txn_type <> v_cat_type then
    signal sqlstate '45000' set message_text = 'txn_type must match category_type';
  end if;
end$$

create trigger trg_txn_check_category_bu
before update on transactions
for each row
begin
  declare v_cat_type enum('income','expense');
  select category_type into v_cat_type from categories where category_id = new.category_id;
  if v_cat_type is null then
    signal sqlstate '45000' set message_text = 'invalid category_id';
  end if;
  if new.txn_type <> v_cat_type then
    signal sqlstate '45000' set message_text = 'txn_type must match category_type';
  end if;
end$$

delimiter ;

-- =============================
-- 6) STORED PROCEDURES (helpers)
-- =============================
delimiter $$

-- 6.1 add a single transaction safely
create procedure sp_add_transaction(
  in p_user_id int,
  in p_account_id int,
  in p_category_id int,
  in p_txn_type enum('income','expense'),
  in p_amount decimal(12,2),
  in p_txn_date date,
  in p_merchant varchar(120),
  in p_note varchar(255)
)
begin
  if p_amount <= 0 then
    signal sqlstate '45000' set message_text = 'amount must be > 0';
  end if;

  insert into transactions(user_id, account_id, category_id, txn_type, amount, txn_date, merchant, note)
  values (p_user_id, p_account_id, p_category_id, p_txn_type, p_amount, p_txn_date, p_merchant, p_note);
end$$

-- 6.2 seed demo data
create procedure sp_seed_finance()
begin
  declare i int default 0;
  declare d date;

  -- user
  insert into users(full_name, email) values ('Dev', 'dev@example.com');

  -- accounts for user 1
  insert into accounts(user_id, account_name, account_type) values
  (1, 'cash in hand', 'cash'),
  (1, 'hdfc savings', 'bank'),
  (1, 'axis credit card', 'card');

  -- categories for user 1
  insert into categories(user_id, category_name, category_type) values
  (1, 'salary', 'income'),
  (1, 'interest', 'income'),
  (1, 'rent', 'expense'),
  (1, 'food', 'expense'),
  (1, 'transport', 'expense'),
  (1, 'shopping', 'expense');

  -- budgets for the current month (1st of month)
  insert into budgets(user_id, category_id, month_year, amount) values
  (1, (select category_id from categories where user_id=1 and category_name='rent' and category_type='expense'), date_format(curdate(), '%Y-%m-01'), 12000.00),
  (1, (select category_id from categories where user_id=1 and category_name='food' and category_type='expense'), date_format(curdate(), '%Y-%m-01'), 6000.00),
  (1, (select category_id from categories where user_id=1 and category_name='transport' and category_type='expense'), date_format(curdate(), '%Y-%m-01'), 2500.00),
  (1, (select category_id from categories where user_id=1 and category_name='shopping' and category_type='expense'), date_format(curdate(), '%Y-%m-01'), 4000.00);

  -- seed last 90 days of random transactions
  set i = 0;
  while i < 90 do
    set d = date_sub(curdate(), interval i day);

    -- monthly salary on the 1st
    if day(d) = 1 then
      call sp_add_transaction(1, 2, (select category_id from categories where user_id=1 and category_name='salary' and category_type='income'), 'income', 45000.00, d, 'company', 'monthly salary');
    end if;

    -- interest income once a month on 15th
    if day(d) = 15 then
      call sp_add_transaction(1, 2, (select category_id from categories where user_id=1 and category_name='interest' and category_type='income'), 'income', 500.00, d, 'bank', 'fd interest');
    end if;

    -- daily small expenses
    call sp_add_transaction(1, 1, (select category_id from categories where user_id=1 and category_name='food' and category_type='expense'), 'expense', round(100 + rand()*200, 2), d, 'zomato', 'meals');
    if weekday(d) in (0,4) then
      call sp_add_transaction(1, 1, (select category_id from categories where user_id=1 and category_name='transport' and category_type='expense'), 'expense', round(50 + rand()*150, 2), d, 'ola/uber', 'commute');
    end if;

    -- occasional shopping on Sundays
    if weekday(d) = 6 and rand() < 0.5 then
      call sp_add_transaction(1, 3, (select category_id from categories where user_id=1 and category_name='shopping' and category_type='expense'), 'expense', round(500 + rand()*3000, 2), d, 'amazon', 'online purchase');
    end if;

    -- rent once a month on 3rd
    if day(d) = 3 then
      call sp_add_transaction(1, 2, (select category_id from categories where user_id=1 and category_name='rent' and category_type='expense'), 'expense', 12000.00, d, 'landlord', 'monthly rent');
    end if;

    set i = i + 1;
  end while;
end$$

delimiter ;

-- =============================
-- 7) RUN SEEDER
-- =============================
call sp_seed_finance();

-- =============================
-- 8) REPORT QUERIES (read-only)
-- =============================

-- 8.1 account balances (per account)
select * from v_account_balance order by account_name;

-- 8.2 monthly summary (income, expense, net)
select * from v_monthly_summary order by user_id, month_start desc;

-- 8.3 top expense categories this month
select 
  user_id,
  month_start,
  category_name,
  spend,
  dense_rank() over (partition by user_id, month_start order by spend desc) as rank_in_month
from v_category_spend_month
where month_start = date_format(curdate(), '%Y-%m-01')
order by spend desc
limit 10;

-- 8.4 budget status for current month
select * from v_budget_status where month_start = date_format(curdate(), '%Y-%m-01') order by over_budget desc, variance desc;

-- 8.5 last 10 transactions (human-friendly)
select 
  t.txn_id,
  t.txn_date,
  t.txn_type,
  concat(case when t.txn_type='income' then '+' else '-' end, format(t.amount, 2)) as amount,
  a.account_name,
  c.category_name,
  t.merchant,
  t.note
from transactions t
join accounts a on a.account_id = t.account_id
join categories c on c.category_id = t.category_id
where t.user_id = 1
order by t.txn_date desc, t.txn_id desc
limit 10;

