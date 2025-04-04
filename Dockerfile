# Based on https://github.com/gianfa/poetry/blob/docs/docker-best-practices/docker-examples/poetry-multistage/Dockerfile
FROM python:3.13-slim as builder

# --- Install Poetry ---
ARG POETRY_VERSION=2.1

ENV POETRY_HOME=/opt/poetry \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_VIRTUALENVS_CREATE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    POETRY_CACHE_DIR=/opt/.cache

RUN pip install "poetry==${POETRY_VERSION}"

WORKDIR /app

# Copy the poetry.lock and pyproject.toml files
COPY pyproject.toml poetry.lock ./

# Install poetry
RUN pip install poetry

COPY pyproject.toml poetry.lock /app/

# Install the dependencies and clear the cache afterwards.
RUN --mount=type=cache,target=$POETRY_CACHE_DIR poetry install --no-root --without dev

# Use a slim image to run the application,
# The alpine version is missing required libs for pydantic and fails to start.
FROM python:3.13-slim as runtime

WORKDIR /app

ENV VIRTUAL_ENV=/app/.venv
ENV PATH="/app/.venv/bin:$PATH"

COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}
COPY my_fastapi_app /app

CMD ["fastapi", "run", "main.py"]