FROM ruby:3.3.0-bullseye

ENV JEKYLL_ENV=production

RUN apt-get update && apt-get install -y nodejs
RUN gem install bundler

WORKDIR /blog

COPY Gemfile ./
RUN bundle install

USER 1000:1000

ENTRYPOINT ["bundle", "exec", "jekyll"]
