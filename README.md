# dbt + Databricks: Retail Sales Medallion Project

A learning/dev project that uses **dbt Core** on **Databricks** to transform raw retail data into analytics-ready tables using the **medallion architecture** (Source → Bronze → Silver → Gold), with **seeds**, **macros**, **tests**, **analyses** and **snapshots (SCD Type 2)**.

| | |
|---|---|
| dbt project name | `pvv_dbt_project` (folder `pvv_dbt_project/`) |
| dbt Core / adapter | `dbt-core 1.12.7`, `dbt-databricks 1.13.1` |
| Python | 3.12 (managed with `uv`, see `pyproject.toml`, `uv.lock`) |
| Warehouse | Databricks SQL Warehouse, Unity Catalog catalog `dbt_dev` |

---

## 1. What this project does

Raw retail tables already live in Databricks (`dbt_dev.source`). dbt reads them, cleans and joins them layer by layer, and writes the results back to Databricks as tables/views.

```
dbt_dev.source      raw tables (not created by dbt)
   │  fact_sales, fact_returns, dim_customer, dim_date,
   │  dim_product, dim_store, items
   ▼
dbt_dev.bronze      1:1 copies of source tables  (bronze_* models) + seed `mapping`
   ▼
dbt_dev.silver      joined and calculated data
   │  sliver_salesinfo  (sales + product category + customer gender, gross_amount)
   │  higher_sales_con  (sales summary by gender)
   ▼
dbt_dev.gold        business-ready data
   │  source_gold_items (deduplicated items: latest row per id)
   ▼
dbt_dev.snapshots   history tracking (SCD Type 2)
      gold_items_snapshot (tracks changes to name/category per item id)
```

### Models

| Layer | Model | Materialization | Description |
|---|---|---|---|
| Bronze | `bronze_sales`, `bronze_date`, `bronze_product`, `bronze_customer`, `bronze_returns` | view | `SELECT *` from the matching source table |
| Bronze | `bronze_store` | table | `SELECT *` from `dim_store` |
| Silver | `sliver_salesinfo` | view | Joins sales with product and customer; calculates `gross_amount` using the `gross_calculated_amount` macro |
| Silver | `higher_sales_con` | table | Per gender: transaction count, total, average, max and min sales |
| Gold | `source_gold_items` | table | Deduplicates `items` using `ROW_NUMBER()` ordered by `updateDate DESC` |
| Snapshot | `gold_items_snapshot` | snapshot | SCD2 history of `source_gold_items`, `check` strategy on `name` and `category` |

### Other project objects

| Object | Location | Purpose |
|---|---|---|
| Seed | `seeds/mapping.csv` | Small customer lookup (id, name, email) loaded into `bronze` |
| Macro | `macros/gross_amount.sql` | `gross_calculated_amount(unit_price, quantity)` returns price × quantity |
| Macro | `macros/generate_schema.sql` | Overrides `generate_schema_name` so `+schema: gold` creates schema `gold`, not `<target_schema>_gold` |
| Analyses | `analyses/` | Ad-hoc SQL (`1_explore_lookup.sql`, `jinja-1.sql`) compiled but never materialized |
| Singular test | `tests/non_negative_test.sql` | Fails if rows with negative amounts exist |
| Generic test | `tests/generic/generic_non_negative_test.sql` | Placeholder for a reusable test (currently empty) |
| Sources | `models/source/source.yml` | Declares the 7 raw tables |

### Folder structure

```
DBT/
├── pyproject.toml / uv.lock / requirements.txt    Python dependencies
├── main.py                                         placeholder
└── pvv_dbt_project/                                ← the dbt project (run dbt from here)
    ├── dbt_project.yml
    ├── analyses/
    ├── macros/
    ├── models/
    │   ├── source/source.yml
    │   ├── bronze/   (*.sql, properties.yml)
    │   ├── silver/
    │   └── gold/
    ├── seeds/mapping.csv
    ├── snapshots/gold_item.yml
    └── tests/
```

---

## 2. Setup

```bash
# 1. Clone and install
git clone https://github.com/VishnuVardhan8055/DBT.git
cd DBT
uv sync                     # or: python -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

# 2. Create ~/.dbt/profiles.yml (never commit this file, it contains secrets)
```

```yaml
# ~/.dbt/profiles.yml
pvv_dbt_project:
  target: dev
  outputs:
    dev:
      type: databricks
      host: <your-workspace>.cloud.databricks.com
      http_path: /sql/1.0/warehouses/<warehouse-id>
      token: "{{ env_var('DATABRICKS_TOKEN') }}"
      catalog: dbt_dev
      schema: default
      threads: 4
```

```bash
# 3. IMPORTANT: always run dbt from inside the project folder
cd pvv_dbt_project
dbt debug      # must end with "All checks passed!"
```

> **Run dbt from `pvv_dbt_project/`** (where `dbt_project.yml` lives). Running from the repo root gives `No dbt_project.yml found`. Alternative from root: `dbt run --project-dir pvv_dbt_project`.

### Typical run order for this project

```bash
dbt seed                         # load mapping.csv
dbt run                          # build bronze → silver → gold models
dbt test                         # data quality checks
dbt snapshot                     # update gold_items_snapshot (dbt run does NOT do this)
# or everything in DAG order, in one command:
dbt build
```

---

## 3. Troubleshooting: snapshot and gold tables not updating in Databricks

Check these in order.

1. **`dbt run` does not execute snapshots.** Run `dbt snapshot` (or `dbt build`). This is the most common reason a snapshot table never changes.
2. **Snapshot runs on a stale gold table.** `gold_items_snapshot` reads `source_gold_items`, so refresh gold first:
   ```bash
   dbt run --select source_gold_items && dbt snapshot
   ```
3. **Gold only changes when the source changes.** `source_gold_items` is a table rebuilt from `dbt_dev.source.items` on every run. If the source rows did not change, the output does not change. Check the source directly in Databricks.
4. **Deduplication can hide updates.** The model keeps the row with the highest `updateDate` per `id`. If a changed row has an `updateDate` that is not newer, the old row still wins.
5. **The `check` strategy only watches `name` and `category`.** A change in any other column does not create a new snapshot version. A brand new `id` does create a row.
6. **Commands failing silently from the wrong folder.** Every command in `logs/dbt.log` (`dbt debug`, `run`, `test`, `parse`) failed with `No dbt_project.yml found at expected path /Users/vishnu/DBT/dbt_project.yml`, because dbt was started in the repo root instead of `pvv_dbt_project/`. Always `cd pvv_dbt_project` first and confirm each command finishes with `Completed successfully`.
7. **Looking in the wrong place.** Because of the `generate_schema_name` macro, tables land in these exact locations:
   - Gold table: `dbt_dev.gold.source_gold_items`
   - Snapshot: `dbt_dev.snapshots.gold_items_snapshot`

   (not `dbt_dev.default.*`). Refresh the Databricks catalog explorer or run the check below.
8. **A selector skipped the model.** `dbt run --select bronze_store` runs only that model. Use `--select source_gold_items+` to include downstream models.

Verify in a Databricks SQL editor:

```sql
DESCRIBE HISTORY dbt_dev.gold.source_gold_items;          -- when was it last written?
SELECT * FROM dbt_dev.snapshots.gold_items_snapshot
ORDER BY id, dbt_valid_from;                              -- versions per id
SELECT * FROM dbt_dev.snapshots.gold_items_snapshot
WHERE dbt_valid_to = DATE'9999-12-31';                    -- current rows (per dbt_valid_to_current)
```

Open `target/run_results.json` or the terminal output after `dbt snapshot` to see the number of rows inserted/updated.

### Other warnings worth cleaning up

- `models/schema.yml` documents `my_first_dbt_model` and `my_second_dbt_model`, which do not exist (starter leftovers). Delete the file or replace it.
- `models/bronze/properties.yml` references `bronze_return`, but the model is `bronze_returns`.
- `bronze_sales` is `table` in `properties.yml` but `view` in its SQL `config()`. The SQL `config()` wins (see precedence below).
- `sliver_salesinfo` looks like a typo of `silver_salesinfo`.
- `logs/dbt.log` and `.DS_Store` are tracked in Git. Add `logs/`, `target/`, `dbt_packages/` and `.DS_Store` to `.gitignore`.

---

## 4. dbt concepts: basics to advanced

### 4.1 Basics

**What is dbt?** dbt (data build tool) is the **T** in ELT. You write `SELECT` statements; dbt compiles them (Jinja + SQL), wraps them in `CREATE TABLE/VIEW AS`, runs them in the right order in your warehouse, tests them, and documents them. It does not extract or load data.

**Core building blocks**

| Concept | What it is |
|---|---|
| Project | Folder with `dbt_project.yml` |
| Profile / target | Connection settings in `~/.dbt/profiles.yml`; a target is one environment (dev, prod) |
| Model | A `.sql` file with one `SELECT`; becomes a table or view |
| Source | Raw table declared in YAML, read with `{{ source('source','items') }}` |
| `ref()` | Reference another model: `{{ ref('bronze_sales') }}`. dbt builds the DAG from these |
| DAG | Dependency graph that decides run order and parallelism |
| Materialization | How a model is stored (view, table, incremental, ephemeral, ...) |
| Seed | Small CSV loaded as a table (`dbt seed`) |
| Test | Assertion about data (`dbt test`) |
| Snapshot | Records how a row changes over time (SCD2) |
| Macro | Reusable Jinja function |
| Analysis | SQL compiled but not run as a model |
| Docs | Auto-generated website with lineage graph |

**Basic commands**

```bash
dbt --version
dbt init <project>          # scaffold a new project
dbt debug                   # test profile + connection
dbt deps                    # install packages from packages.yml
dbt compile                 # render Jinja to SQL in target/compiled
dbt run                     # build models
dbt seed                    # load CSVs
dbt test                    # run tests
dbt snapshot                # run snapshots
dbt build                   # seed + run + snapshot + test, in DAG order
dbt clean                   # delete target/ and dbt_packages/
dbt docs generate && dbt docs serve
```

### 4.2 Project configuration

Config can be set in three places. Precedence, highest first:

1. `{{ config(...) }}` block inside the model SQL
2. `config:` in a properties YAML file
3. `dbt_project.yml` (folder-level, uses `+` prefix)

```yaml
# dbt_project.yml
models:
  pvv_dbt_project:
    bronze:
      +materialized: table
      +schema: bronze
```

**Custom schemas.** By default dbt creates `<target.schema>_<custom_schema>` (e.g. `default_gold`). This project overrides `generate_schema_name` in `macros/generate_schema.sql` so the schema is exactly `gold`.

### 4.3 Materializations

| Type | Behaviour | Use when |
|---|---|---|
| `view` | Stores the query | Light transforms, small data |
| `table` | Rebuilt fully each run | Heavily queried, moderate size |
| `incremental` | Adds/updates only new rows | Large, append-heavy data |
| `ephemeral` | Inlined as a CTE, nothing created | Small reusable logic |
| `materialized_view` | Warehouse-maintained refreshing view | Supported on Databricks |

### 4.4 Sources, freshness and the DAG

```yaml
sources:
  - name: source
    database: dbt_dev
    schema: source
    tables:
      - name: items
        loaded_at_field: updateDate
        freshness:
          warn_after: {count: 24, period: hour}
          error_after: {count: 48, period: hour}
```

```bash
dbt source freshness
```

### 4.5 Tests

**Generic tests (built in):** `unique`, `not_null`, `accepted_values`, `relationships`.

```yaml
models:
  - name: source_gold_items
    columns:
      - name: id
        data_tests:
          - unique
          - not_null
```

**Singular test:** a SQL file in `tests/` that returns the *failing* rows (see `tests/non_negative_test.sql`).

**Custom generic test:** reusable and parameterized.

```sql
-- tests/generic/non_negative.sql  (or macros/)
{% test non_negative(model, column_name) %}
select * from {{ model }} where {{ column_name }} < 0
{% endtest %}
```

```yaml
columns:
  - name: gross_amount
    data_tests:
      - non_negative
```

```bash
dbt test
dbt test --select source_gold_items
dbt test --select test_type:generic
dbt test --select test_type:singular
dbt test --store-failures        # save failing rows in the warehouse
```

### 4.6 Jinja and macros

```sql
{% set cols = ['date_sk', 'sales_id', 'net_amount'] %}
select
  {% for c in cols %} {{ c }}{% if not loop.last %},{% endif %} {% endfor %}
from {{ ref('bronze_sales') }}
{% if var('inc_flag', 0) == 1 %} where date_sk > {{ var('last_load', 0) }} {% endif %}
```

Macro from this project:

```sql
{% macro gross_calculated_amount(unit_price, quantity) %}
    {{ unit_price }} * {{ quantity }}
{% endmacro %}
```

Useful Jinja tools: `{{ this }}`, `{{ target.name }}`, `{{ var('x') }}`, `{{ env_var('X') }}`, `is_incremental()`, `run_query()`, `log()`.

### 4.7 Seeds

CSV files in `seeds/`, loaded with `dbt seed`. Use for small static lookups only. Reference with `{{ ref('mapping') }}`.

```bash
dbt seed
dbt seed --select mapping --full-refresh
```

### 4.8 Snapshots (SCD Type 2)

Snapshots keep history when a source row changes. dbt adds `dbt_scd_id`, `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to`.

```yaml
# snapshots/gold_item.yml  (YAML snapshots, dbt 1.9+)
snapshots:
  - name: gold_items_snapshot
    relation: ref('source_gold_items')
    config:
      schema: snapshots
      database: dbt_dev
      unique_key: id
      strategy: check            # or: timestamp
      check_cols: [name, category]
      dbt_valid_to_current: "to_date('9999-12-31')"   # open rows get this date instead of NULL
```

| Strategy | Detects change by | Config |
|---|---|---|
| `timestamp` (preferred) | An `updated_at` column | `updated_at: updateDate` |
| `check` | Comparing listed columns (`check_cols`, or `all`) | `check_cols: [...]` |

```bash
dbt snapshot
dbt snapshot --select gold_items_snapshot
```

Remember: `dbt run` never runs snapshots.

### 4.9 Documentation

```yaml
models:
  - name: higher_sales_con
    description: "Sales summary by gender"
    columns:
      - name: total_sales
        description: "Sum of gross_amount"
```

```bash
dbt docs generate
dbt docs serve --port 8080       # lineage graph in the browser
```

### 4.10 Node selection (very important)

```bash
dbt run --select bronze_sales            # one model
dbt run --select +sliver_salesinfo       # model and all upstream
dbt run --select source_gold_items+      # model and all downstream
dbt run --select +higher_sales_con+      # both directions
dbt run --select 2+higher_sales_con      # 2 levels upstream
dbt run --select path:models/silver      # a folder
dbt run --select tag:daily               # by tag
dbt run --select config.materialized:view
dbt run --exclude bronze_store
dbt run --select "bronze,tag:daily"      # intersection (comma)
dbt run --select "bronze silver"         # union (space)
dbt ls --select +higher_sales_con        # list without running
```

### 4.11 Intermediate and advanced topics

**Incremental models**

```sql
{{ config(
    materialized='incremental',
    unique_key='sales_id',
    incremental_strategy='merge'        -- Databricks: append, merge, insert_overwrite, replace_where, microbatch
) }}

select * from {{ ref('bronze_sales') }}
{% if is_incremental() %}
  where date_sk > (select max(date_sk) from {{ this }})
{% endif %}
```

```bash
dbt run --select my_model                  # incremental load
dbt run --select my_model --full-refresh   # rebuild from scratch
```

**Packages** (`packages.yml`, then `dbt deps`)

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.1.0", "<2.0.0"]
```

Examples: `dbt_utils.generate_surrogate_key`, `dbt_utils.star`, `dbt_expectations`, `dbt_project_evaluator`.

**Hooks and operations**

```yaml
models:
  pvv_dbt_project:
    +post-hook: "OPTIMIZE {{ this }}"
```

```bash
dbt run-operation my_macro --args '{key: value}'
```

`on-run-start` and `on-run-end` hooks run once per invocation.

**Variables and environments**

```bash
dbt run --vars '{inc_flag: 1, last_load: 3}'
dbt run --target prod
```

**Databricks-specific configs**

```sql
{{ config(
    materialized='table',
    file_format='delta',
    liquid_clustered_by=['id'],
    partition_by=['category'],
    tblproperties={'delta.autoOptimize.optimizeWrite': 'true'}
) }}
```

Unity Catalog three-level naming (`catalog.schema.table`) comes from `database`/`schema` in config.

**Contracts, constraints, versions**

```yaml
models:
  - name: source_gold_items
    config: {contract: {enforced: true}}
    columns:
      - name: id
        data_type: int
        constraints: [{type: not_null}]
      - name: name
        data_type: string
```

Model versions (`versions:` with `latest_version`) allow breaking changes with a deprecation window. Access modifiers (`access: public|protected|private`) and `group:` support multi-team projects.

**Unit tests (dbt 1.8+)** test SQL logic with fixed mock inputs, no warehouse data needed:

```yaml
unit_tests:
  - name: test_gross_amount
    model: sliver_salesinfo
    given:
      - input: ref('bronze_sales')
        rows: [{sales_id: 1, unit_price: 10, quantity: 3}]
    expect:
      rows: [{sales_id: 1, gross_amount: 30}]
```

```bash
dbt test --select test_type:unit
```

**Exposures, metrics and the Semantic Layer.** `exposures:` document dashboards that use your models. `semantic_models` and `metrics` (MetricFlow, listed in `requirements.txt`) define governed business metrics.

**State, defer and slim CI**

```bash
dbt build --select state:modified+ --defer --state ./prod-artifacts
dbt clone --state ./prod-artifacts       # zero-copy clone on Databricks
```

Only changed models and their children are built; unchanged upstream models are read from production.

**Debugging and developer tools**

```bash
dbt parse                         # validate project without a connection to run queries
dbt compile --select my_model     # inspect final SQL in target/compiled
dbt show --select my_model --limit 10   # preview results
dbt run --empty                   # build structure with zero rows (schema check)
dbt retry                         # re-run only failed nodes from last run
dbt run --fail-fast               # stop on first error
dbt --debug run                   # verbose logs
dbt run -x --threads 8
```

Logs are in `logs/dbt.log`; compiled/executed SQL is in `target/`.

### 4.12 CI/CD pattern

1. Pull request → `dbt build --select state:modified+ --defer --state prod-artifacts --target ci`
2. Merge to main → scheduled production job (Databricks Workflows, GitHub Actions, Airflow or dbt platform) running `dbt build --target prod`
3. Save `target/manifest.json` as the artifact for next time's `--state`.

### 4.13 Best practices

- Layer models: sources → staging/bronze → intermediate/silver → marts/gold.
- One source reference per staging model; join only in silver and above.
- Name models consistently (`bronze_`, `silver_`, `gold_`).
- Test every primary key (`unique`, `not_null`) and key relationships.
- Prefer `timestamp` snapshots; they are faster and more reliable than `check`.
- Use incremental models only when data size justifies it.
- Keep secrets in `env_var()`; never commit `profiles.yml`.
- Do not commit `target/`, `logs/`, `dbt_packages/`.

---

## 5. Command cheat sheet

| Goal | Command |
|---|---|
| Check connection | `dbt debug` |
| Install packages | `dbt deps` |
| Load CSVs | `dbt seed` |
| Build all models | `dbt run` |
| Build one model + upstream | `dbt run --select +model_name` |
| Run tests | `dbt test` |
| Update snapshots | `dbt snapshot` |
| Everything in order | `dbt build` |
| Full rebuild of incremental | `dbt run --full-refresh` |
| Compile only | `dbt compile` |
| Validate project | `dbt parse` |
| List nodes | `dbt ls --select ...` |
| Source freshness | `dbt source freshness` |
| Generate and view docs | `dbt docs generate && dbt docs serve` |
| Run a macro | `dbt run-operation macro_name` |
| Retry failures | `dbt retry` |
| Other environment | `dbt run --target prod` |

## 6. Resources

- dbt docs: https://docs.getdbt.com
- dbt-databricks adapter: https://docs.getdbt.com/docs/core/connect-data-platform/databricks-setup
- dbt Community: https://community.getdbt.com
