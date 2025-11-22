#!/bin/bash
set -e

# === 🔐 КОНФИГУРАЦИЯ — измените значения! ===
DB_NAME="price_monitor"
DB_USER="price_user"
DB_PASS="ваш_надёжный_пароль"          # ← ОБЯЗАТЕЛЬНО ИЗМЕНИТЬ
TELEGRAM_BOT_TOKEN="1234567890:ABCdefGhIJKlmNoPQRsTUVwxyZ"  # ← ваш токен
TELEGRAM_CHAT_ID="123456789"               # ← ваш chat_id
ADMIN_PASSWORD="ваш_пароль_админки"       # ← пароль для входа в /admin
PROJECT_DIR="$HOME/projects/check_prices"

echo "🚀 Запуск установки мониторинга цен Ozon..."

# === 1. Системные пакеты ===
sudo apt update
sudo apt install -y \
    python3 python3-pip python3-venv \
    mysql-server mysql-client \
    wget gnupg unzip software-properties-common \
    libmysqlclient-dev build-essential

# === 2. MySQL ===
sudo systemctl start mysql
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# === 3. Google Chrome ===
wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
sudo apt update
sudo apt install -y google-chrome-stable

# === 4. ChromeDriver ===
CHROME_VERSION=$(google-chrome --version | grep -oP '\d+\.\d+\.\d+' || echo "120.0.0")
DRIVER_VERSION=$(curl -s "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('channels',{}).get('Stable',{}).get('version','120.0.0'))" 2>/dev/null || echo "120.0.0")
wget -O /tmp/chromedriver.zip "https://edgedl.me.gvt1.com/edgedl/chrome/chrome-for-testing/${DRIVER_VERSION}/linux64/chromedriver-linux64.zip"
sudo unzip -o /tmp/chromedriver.zip -d /usr/local/bin/
sudo mv /usr/local/bin/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver
sudo chmod +x /usr/local/bin/chromedriver
rm -f /tmp/chromedriver.zip

# === 5. Проект ===
mkdir -p "$PROJECT_DIR/templates"
cd "$PROJECT_DIR"

# === 6. Виртуальное окружение ===
python3 -m venv venv
source venv/bin/activate

cat > requirements.txt <<'EOF'
Flask==3.0.3
selenium==4.21.0
selenium-stealth==1.0.6
beautifulsoup4==4.12.3
python-telegram-bot==20.7
mysql-connector-python==9.1.0
python-dotenv==1.0.1
requests
EOF

pip install -r requirements.txt

# === 7. .env ===
cat > .env <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
PRICE_ALERT_THRESHOLD=500
MYSQL_HOST=localhost
MYSQL_USER=$DB_USER
MYSQL_PASSWORD=$DB_PASS
MYSQL_DB=$DB_NAME
FLASK_SECRET_KEY=$(openssl rand -hex 24)
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
chmod 600 .env

# === 8. config.py ===
cat > config.py <<'EOF'
import os
from dotenv import load_dotenv

load_dotenv()

BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
PRICE_ALERT_THRESHOLD = int(os.getenv('PRICE_ALERT_THRESHOLD', '500'))

MYSQL_HOST = os.getenv('MYSQL_HOST', 'localhost')
MYSQL_USER = os.getenv('MYSQL_USER', 'price_user')
MYSQL_PASSWORD = os.getenv('MYSQL_PASSWORD')
MYSQL_DB = os.getenv('MYSQL_DB', 'price_monitor')

FLASK_SECRET_KEY = os.getenv('FLASK_SECRET_KEY', 'fallback-insecure-key-change-in-prod!')
ADMIN_PASSWORD = os.getenv('ADMIN_PASSWORD', 'admin123')
EOF

# === 9. utils.py ===
cat > utils.py <<'EOF'
import time
import re
import logging
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium_stealth import stealth

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("Ozon_Price_Extractor")

def setup_driver():
    options = Options()
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--disable-blink-features=AutomationControlled')
    options.add_argument('--disable-extensions')
    options.add_argument('--headless=new')
    options.add_argument(
        '--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    )
    options.add_experimental_option("excludeSwitches", ["enable-automation"])
    options.add_experimental_option('useAutomationExtension', False)

    driver = webdriver.Chrome(options=options)

    stealth(driver,
            languages=["ru-RU", "ru"],
            vendor="Google Inc.",
            platform="Win32",
            webgl_vendor="Intel Inc.",
            renderer="Intel Iris OpenGL Engine",
            fix_hairline=True,
            )

    driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
    return driver

def extract_price_from_ozon(url: str) -> int | None:
    driver = None
    try:
        driver = setup_driver()
        logger.info(f"Открываем карточку товара: {url}")
        driver.get(url)
        WebDriverWait(driver, 20).until(EC.presence_of_element_located((By.TAG_NAME, "body")))
        time.sleep(3)
        page_text = driver.find_element(By.TAG_NAME, "body").text

        price_patterns = [
            r'(\d{1,3}[ \s]?\d{3}[ \s]?\d{0,3})[ \s]?₽',
            r'₽[ \s]*(\d{1,3}[ \s]?\d{3}[ \s]?\d{0,3})',
            r'(\d{4,6})\s*руб'
        ]

        for pattern in price_patterns:
            matches = re.findall(pattern, page_text, re.IGNORECASE)
            for match in matches:
                price_str = match if isinstance(match, str) else (match[0] if match else "")
                if price_str:
                    clean_price = re.sub(r'[^\d]', '', price_str)
                    if clean_price.isdigit():
                        price = int(clean_price)
                        if 1000 <= price <= 500000:
                            logger.info(f"✅ Найдена цена: {price} ₽ на {url}")
                            return price

        price_selectors = [
            "span[class*='price']", "div[class*='price']",
            "span[class*='cost']", "div[class*='cost']",
            "[data-widget*='price']", ".c311-a1", ".a3214"
        ]

        for selector in price_selectors:
            try:
                elements = driver.find_elements(By.CSS_SELECTOR, selector)
                for el in elements:
                    text = el.text.strip()
                    if text:
                        clean = re.sub(r'[^\d\s]', '', text)
                        clean = re.sub(r'\s+', '', clean)
                        if clean.isdigit():
                            price = int(clean)
                            if 1000 <= price <= 500000:
                                logger.info(f"✅ Цена через селектор: {price} ₽")
                                return price
            except Exception:
                continue

        logger.warning(f"⚠️ Цена не найдена на {url}")
        return None

    except Exception as e:
        logger.error(f"❌ Ошибка при парсинге {url}: {e}")
        return None

    finally:
        if driver:
            driver.quit()
EOF

# === 10. templates/admin.html ===
mkdir -p templates
cat > templates/admin.html <<'EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Мониторинг цен — Админка</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { padding: 20px; background: #f8f9fa; }
        .product-card { margin-bottom: 1.5rem; }
        .price-badge { font-size: 1.1em; }
    </style>
</head>
<body>
<div class="container">
    <h2 class="mb-4">⚙️ Панель управления мониторингом цен</h2>

    <div class="card mb-4">
        <div class="card-body">
            <h5>Порог уведомления</h5>
            <form method="POST" action="/admin/set-threshold" class="row g-2">
                <div class="col-auto">
                    <input type="number" name="threshold" value="{{ threshold }}" class="form-control" min="1">
                </div>
                <div class="col-auto">
                    <button type="submit" class="btn btn-primary">Сохранить</button>
                </div>
                <div class="col-auto">
                    Уведомлять, если ваша цена ВЫШЕ цены Ozon на эту сумму (₽)
                </div>
            </form>
        </div>
    </div>

    <h4>Товары (всего: {{ products|length }})</h4>
    {% for p in products %}
    <div class="card product-card">
        <div class="card-body">
            <form method="POST" action="/admin/edit/{{ p.id }}" class="row g-2 align-items-end">
                <div class="col-md-2">
                    <input type="text" name="name" value="{{ p.name }}" class="form-control" placeholder="Название" required>
                </div>
                <div class="col-md-4">
                    <input type="url" name="url" value="{{ p.url }}" class="form-control" placeholder="Ссылка на Ozon" required>
                </div>
                <div class="col-md-2">
                    <input type="number" name="my_price" value="{{ p.my_price }}" class="form-control" min="1" required>
                </div>
                <div class="col-md-2">
                    {% if p.last_competitor_price %}
                        <span class="badge bg-info price-badge">Ozon: {{ p.last_competitor_price }} ₽</span>
                    {% else %}
                        <span class="badge bg-secondary">Цена не проверялась</span>
                    {% endif %}
                </div>
                <div class="col-md-2">
                    <button type="submit" class="btn btn-sm btn-success">Сохранить</button>
                    <a href="/admin/delete/{{ p.id }}" class="btn btn-sm btn-danger" onclick="return confirm('Удалить?')">Удалить</a>
                </div>
            </form>
        </div>
    </div>
    {% endfor %}

    <div class="card mt-4">
        <div class="card-header">➕ Добавить новый товар</div>
        <div class="card-body">
            <form method="POST" action="/admin/add" class="row g-2">
                <div class="col-md-2">
                    <input type="text" name="name" class="form-control" placeholder="Название" required>
                </div>
                <div class="col-md-4">
                    <input type="url" name="url" class="form-control" placeholder="Ссылка на Ozon" required>
                </div>
                <div class="col-md-2">
                    <input type="number" name="my_price" class="form-control" min="1" placeholder="Ваша цена" required>
                </div>
                <div class="col-md-2">
                    <button type="submit" class="btn btn-primary">Добавить</button>
                </div>
            </form>
        </div>
    </div>

    <div class="mt-4">
        <a href="/check" class="btn btn-warning" target="_blank">🔄 Запустить проверку вручную</a>
        <a href="/admin/logout" class="btn btn-outline-secondary">Выйти</a>
    </div>
</div>
</body>
</html>
EOF

# === 11. app.py (полный) ===
cat > app.py <<'EOF'
import os
import time
import threading
from datetime import datetime
import requests
from flask import Flask, render_template, request, redirect, url_for, session, flash
from utils import extract_price_from_ozon
from config import (
    BOT_TOKEN, CHAT_ID, PRICE_ALERT_THRESHOLD,
    MYSQL_HOST, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DB,
    FLASK_SECRET_KEY, ADMIN_PASSWORD
)
import mysql.connector

app = Flask(__name__)
app.secret_key = FLASK_SECRET_KEY

def get_db_connection():
    return mysql.connector.connect(
        host=MYSQL_HOST,
        user=MYSQL_USER,
        password=MYSQL_PASSWORD,
        database=MYSQL_DB,
        autocommit=True
    )

def load_products():
    conn = get_db_connection()
    cursor = conn.cursor(dictionary=True)
    cursor.execute("SELECT * FROM products ORDER BY name")
    products = cursor.fetchall()
    cursor.close()
    conn.close()
    return products

def update_product_price(product_id, competitor_price):
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute(
        "UPDATE products SET last_competitor_price = %s, last_checked_at = %s WHERE id = %s",
        (competitor_price, datetime.now(), product_id)
    )
    cursor.close()
    conn.close()

def send_telegram_message(text):
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    try:
        response = requests.post(url, data={'chat_id': CHAT_ID, 'text': text}, timeout=10)
        if response.status_code == 200:
            print("✅ Уведомление отправлено в Telegram")
        else:
            print(f"❌ Ошибка Telegram API: {response.text}")
    except Exception as e:
        print(f"❌ Ошибка отправки: {e}")

def check_and_notify_if_needed(product_id, name, url, my_price, competitor_price):
    if my_price - competitor_price >= PRICE_ALERT_THRESHOLD:
        message = (
            f"⚠️ Ваша цена ВЫШЕ цены Ozon!\n"
            f"Товар: {name}\n"
            f"Ссылка: {url}\n"
            f"Ваша цена: {my_price} ₽\n"
            f"Цена на Ozon: {competitor_price} ₽\n"
            f"Переплата: {my_price - competitor_price} ₽"
        )
        print(f"📩 Отправка уведомления: переплата {my_price - competitor_price} ₽")
        send_telegram_message(message)
    else:
        print(f"✅ {name}: переплата {my_price - competitor_price} ₽ (порог: {PRICE_ALERT_THRESHOLD})")

def create_table_if_not_exists():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS products (
            id INT AUTO_INCREMENT PRIMARY KEY,
            name VARCHAR(255) NOT NULL,
            url TEXT NOT NULL,
            my_price INT NOT NULL,
            last_competitor_price INT NULL,
            last_checked_at DATETIME NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    """)
    cursor.close()
    conn.close()

def initialize_db_from_files():
    create_table_if_not_exists()
    products = load_products()
    if products:
        return
    print("📥 Инициализация из файлов...")
    try:
        if os.path.exists('links.txt') and os.path.exists('my_prices.txt'):
            links = [line.strip() for line in open('links.txt', encoding='utf-8') if line.strip()]
            my_prices = {}
            for line in open('my_prices.txt', encoding='utf-8'):
                if line.strip():
                    parts = line.strip().split(maxsplit=1)
                    if len(parts) == 2:
                        key = parts[0].lower()
                        try:
                            my_prices[key] = int(parts[1])
                        except ValueError:
                            continue
            if links and my_prices:
                conn = get_db_connection()
                cursor = conn.cursor()
                keys = list(my_prices.keys())
                for i, url in enumerate(links):
                    name = keys[i] if i < len(keys) else f"product_{i}"
                    price = my_prices.get(name, 0)
                    if price > 0:
                        cursor.execute("INSERT INTO products (name, url, my_price) VALUES (%s, %s, %s)", (name, url, price))
                conn.commit()
                cursor.close()
                conn.close()
                print("✅ БД инициализирована из файлов")
    except Exception as e:
        print(f"[ERROR] Инициализация: {e}")

def require_login(f):
    from functools import wraps
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('admin_login'))
        return f(*args, **kwargs)
    return decorated_function

@app.route('/admin/login', methods=['GET', 'POST'])
def admin_login():
    if request.method == 'POST':
        if request.form.get('password') == ADMIN_PASSWORD:
            session['logged_in'] = True
            return redirect('/admin')
        else:
            flash("Неверный пароль", "error")
    return '''
    <form method="post" style="max-width:300px;margin:100px auto;text-align:center;">
        <h3>Вход в панель управления</h3>
        <input type="password" name="password" placeholder="Пароль" required style="width:100%;padding:10px;margin:10px 0;">
        <button type="submit" style="width:100%;padding:10px;background:#4CAF50;color:white;border:none;">Войти</button>
    </form>
    '''

@app.route('/admin/logout')
def admin_logout():
    session.pop('logged_in', None)
    return redirect('/admin/login')

@app.route('/')
def index():
    return "Сервис мониторинга цен запущен. <a href='/admin'>Админка</a>"

@app.route('/check')
def manual_check():
    threading.Thread(target=check_prices_job, daemon=True).start()
    return "✅ Проверка запущена", 200

@app.route('/admin')
@require_login
def admin_panel():
    products = load_products()
    return render_template('admin.html', products=products, threshold=PRICE_ALERT_THRESHOLD)

@app.route('/admin/add', methods=['POST'])
@require_login
def add_product():
    name = request.form['name'].strip()
    url = request.form['url'].strip()
    try:
        my_price = int(request.form['my_price'])
    except ValueError:
        my_price = 0
    if name and url and my_price > 0:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("INSERT INTO products (name, url, my_price) VALUES (%s, %s, %s)", (name, url, my_price))
        conn.commit()
        cursor.close()
        conn.close()
        competitor_price = extract_price_from_ozon(url)
        if competitor_price is not None:
            check_and_notify_if_needed(None, name, url, my_price, competitor_price)
    return redirect('/admin')

@app.route('/admin/edit/<int:product_id>', methods=['POST'])
@require_login
def edit_product(product_id):
    name = request.form['name'].strip()
    url = request.form['url'].strip()
    try:
        my_price = int(request.form['my_price'])
    except ValueError:
        my_price = 0
    if name and url and my_price > 0:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("UPDATE products SET name=%s, url=%s, my_price=%s WHERE id=%s", (name, url, my_price, product_id))
        conn.commit()
        cursor.close()
        conn.close()
        competitor_price = extract_price_from_ozon(url)
        if competitor_price is not None:
            check_and_notify_if_needed(product_id, name, url, my_price, competitor_price)
    return redirect('/admin')

@app.route('/admin/delete/<int:product_id>')
@require_login
def delete_product(product_id):
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM products WHERE id = %s", (product_id,))
    conn.commit()
    cursor.close()
    conn.close()
    return redirect('/admin')

@app.route('/admin/set-threshold', methods=['POST'])
@require_login
def set_threshold():
    try:
        new_limit = int(request.form['threshold'])
        with open('limit.txt', 'w') as f:
            f.write(str(new_limit))
        global PRICE_ALERT_THRESHOLD
        PRICE_ALERT_THRESHOLD = new_limit
    except Exception as e:
        print(f"Ошибка обновления порога: {e}")
    return redirect('/admin')

def check_prices_job():
    products = load_products()
    for prod in products:
        url = prod['url']
        my_price = prod['my_price']
        name = prod['name']
        product_id = prod['id']
        print(f"🔍 Проверка: {name} — {url}")
        competitor_price = extract_price_from_ozon(url)
        if competitor_price is not None:
            update_product_price(product_id, competitor_price)
            check_and_notify_if_needed(product_id, name, url, my_price, competitor_price)
        else:
            print(f"⚠️ Не удалось получить цену для {name}")
        time.sleep(5)
    print("🔄 Цикл проверки завершён")

if __name__ == '__main__':
    initialize_db_from_files()
    threading.Thread(target=check_prices_job, daemon=True).start()
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# === 12. Права и логи ===
mkdir -p logs
touch logs/app.log
chmod -R 755 "$PROJECT_DIR"
chmod 600 .env

# === 13. systemd (если доступен) ===
if systemctl --version &>/dev/null && systemctl list-units --full --all | grep -q "systemd"; then
    echo "⚙️ Настройка systemd..."
    sudo tee /etc/systemd/system/price_monitor.service > /dev/null <<EOF
[Unit]
Description=Price Monitor — Ozon Competitor Tracker
After=network.target mysql.service

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$PROJECT_DIR
Environment=PATH=$PROJECT_DIR/venv/bin
Environment=VIRTUAL_ENV=$PROJECT_DIR/venv
ExecStart=$PROJECT_DIR/venv/bin/python app.py
Restart=always
RestartSec=30
StandardOutput=append:$PROJECT_DIR/logs/app.log
StandardError=append:$PROJECT_DIR/logs/app.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    echo "✅ Запустите: sudo systemctl start price_monitor && sudo systemctl enable price_monitor"
else
    echo "ℹ️ systemd недоступен. Запустите вручную:"
    echo "   cd $PROJECT_DIR && source venv/bin/activate && python app.py"
fi

echo "🎉 Установка завершена!"
echo "🌐 Админка: http://localhost:5000/admin"
