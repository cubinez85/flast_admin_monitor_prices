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
