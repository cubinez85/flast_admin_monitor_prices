# config.py
import os
from dotenv import load_dotenv

# Загружаем переменные из .env
load_dotenv()

# Telegram
BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')

# Порог уведомления (в рублях)
try:
    PRICE_ALERT_THRESHOLD = int(os.getenv('PRICE_ALERT_THRESHOLD', '500'))
except ValueError:
    PRICE_ALERT_THRESHOLD = 500

# MySQL
MYSQL_HOST = os.getenv('MYSQL_HOST', 'localhost')
MYSQL_USER = os.getenv('MYSQL_USER', 'price_user')
MYSQL_PASSWORD = os.getenv('MYSQL_PASSWORD')
MYSQL_DB = os.getenv('MYSQL_DB', 'price_monitor')

# Flask и безопасность
FLASK_SECRET_KEY = os.getenv('FLASK_SECRET_KEY', 'fallback-insecure-key-change-in-prod!')
ADMIN_PASSWORD = os.getenv('ADMIN_PASSWORD', 'admin123')
