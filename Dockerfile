FROM ghcr.io/gozargah/marzban:v0.8.4

WORKDIR /code
COPY . /code

CMD ["bash", "-c", "alembic upgrade head; python main.py"]
