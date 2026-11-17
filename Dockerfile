# Use the correct Ruby version
FROM --platform=linux/amd64 ruby:3.2.1-alpine

# Install system dependencies
RUN apk add --no-cache \
    build-base \
    nodejs \
    npm \
    postgresql-dev \
    tzdata \
    git \
    imagemagick \
    yarn \
    libxml2-dev \
    libxslt-dev \
    zlib-dev  

# Set working directory
WORKDIR /app

# Copy Gemfile first to leverage Docker cache
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Fix Bundler issues and install gems
RUN bundle config set --local without 'development test' && bundle install

# Copy package.json and install frontend dependencies
COPY package.json yarn.lock ./
RUN yarn install --production


# Copy the rest of the application
COPY . .

# Create tmp directories that Rails needs at runtime
RUN mkdir -p tmp/pids tmp/cache tmp/sockets

# Ensure entrypoint is executable
RUN chmod +x ./docker-entry.sh

# Precompile Rails assets using temporary build-only values
RUN SECRET_KEY_BASE=dummy \
    DATABASE_USER=dummy \
    DB_PASSWORD=dummy \
    DATABASE_NAME=dummy \
    DATABASE_HOST=localhost \
    RAILS_ENV=production \
    bundle exec rails assets:precompile
# Expose (harmless on Cloud Run)
EXPOSE 8080

# Entrypoint must be executable and should NOT duplicate "bundle exec" in CMD
ENTRYPOINT ["./docker-entry.sh"]

# Let Puma (via config/puma.rb) pick up ENV["PORT"] from Cloud Run
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]