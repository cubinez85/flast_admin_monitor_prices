import os
import time
import threading
import requests
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, session, flash
from telegram import Bot
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
        response = requests.post(url, data={'chat_id': CHAT_ID, 'text': text})
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

        if not links or not my_prices:
            return

        conn = get_db_connection()
        cursor = conn.cursor()
        keys = list(my_prices.keys())
        for i, url in enumerate(links):
            name = keys[i] if i < len(keys) else f"product_{i}"
            price = my_prices.get(name, 0)
            if price > 0:
                cursor.execute(
                    "INSERT INTO products (name, url, my_price) VALUES (%s, %s, %s)",
                    (name, url, price)
                )
        conn.commit()
        cursor.close()
        conn.close()
        print("✅ БД инициализирована")
    except Exception as e:
        print(f"[ERROR] Инициализация: {e}")

# === Админка ===

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
        cursor.execute(
            "INSERT INTO products (name, url, my_price) VALUES (%s, %s, %s)",
            (name, url, my_price)
        )
        conn.commit()
        cursor.close()
        conn.close()
        # Проверка после добавления
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
        cursor.execute(
            "UPDATE products SET name=%s, url=%s, my_price=%s WHERE id=%s",
            (name, url, my_price, product_id)
        )
        conn.commit()
        cursor.close()
        conn.close()
        # Мгновенная проверка после редактирования
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

# === Фоновая проверка ===

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

# === Запуск ===

if __name__ == '__main__':
    initialize_db_from_files()
    threading.Thread(target=lambda: check_prices_job(), daemon=True).start()
    app.run(host='0.0.0.0', port=5000, debug=False)
