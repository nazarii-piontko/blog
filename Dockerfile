FROM ruby:3.3-bullseye

RUN apt-get update && apt-get install -y nodejs
RUN gem install bundler

WORKDIR /blog

COPY Gemfile ./
RUN bundle install

ENV JEKYLL_ENV=production

ENTRYPOINT ["bundle", "exec", "jekyll"]
