FROM ruby:3.3-bullseye

RUN gem install bundler

WORKDIR /data

COPY Gemfile ./

RUN bundle install

USER 1000:1000

ENV JEKYLL_ENV=production

ENTRYPOINT ["bundle", "exec", "jekyll"]
