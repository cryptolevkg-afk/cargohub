// Применяет schema.sql при старте сервиса, но только один раз — безопасно
// вызывать при каждом деплое. Render не даёт зайти в базу вручную на
// бесплатном плане так же просто, как в Railway, поэтому миграция встроена
// в команду запуска: node scripts/migrate.js && node src/server.js

const fs = require("fs");
const path = require("path");
const { Pool } = require("pg");

async function main() {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });

  const { rows } = await pool.query("SELECT to_regclass('public.users') AS exists");
  if (rows[0].exists) {
    console.log("Схема уже применена — пропускаю миграцию.");
    await pool.end();
    return;
  }

  console.log("Применяю schema.sql...");
  const schemaPath = path.join(__dirname, "..", "schema.sql");
  const sql = fs.readFileSync(schemaPath, "utf8");
  await pool.query(sql);
  console.log("Готово.");
  await pool.end();
}

main().catch((e) => {
  console.error("Ошибка миграции:", e.message);
  process.exit(1);
});
