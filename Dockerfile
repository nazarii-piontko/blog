FROM ruby:3.2-bullseye

RUN gem install bundler

WORKDIR /data

COPY Gemfile ./
RUN bundle install

USER 1000:1000

ENTRYPOINT ["bundle", "exec", "jekyll"]
