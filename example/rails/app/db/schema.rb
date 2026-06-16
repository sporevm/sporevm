ActiveRecord::Schema[7.2].define(version: 2026_06_16_000001) do
  create_table "widgets", force: :cascade do |t|
    t.string "name", null: false
    t.timestamps null: false
  end
end
