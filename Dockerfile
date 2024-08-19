FROM ruby:3.3-bullseye

RUN apt-get update && apt-get install -y nodejs
RUN gem install bundler

WORKDIR /blog

COPY Gemfile ./
RUN bundle install

ENV JEKYLL_ENV=production

USER 1000:1000

ENTRYPOINT ["bundle", "exec", "jekyll"]
