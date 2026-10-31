FROM ruby:4.0-bookworm

ENV JEKYLL_ENV=production

RUN apt-get update && apt-get install -y nodejs default-jre graphviz
RUN gem install bundler

WORKDIR /blog

COPY Gemfile ./
RUN bundle install

USER 1000:1000

ENTRYPOINT ["bundle", "exec", "jekyll"]
