---
layout: default
title: 整うデスク
---

<section class="hero">
  <h1 class="hero__title">整うデスク</h1>
  <p class="hero__lead">机の上が整うと、頭の中も整う。<br>余計なものを手放して、心地よくととのうデスクをつくります。</p>
</section>

<section class="post-list">
  <h2 class="post-list__heading">記事一覧</h2>
  {% if site.posts.size > 0 %}
  <ul class="post-list__items">
    {% for post in site.posts %}
    <li class="post-list__item">
      <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
      <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: '%Y年%m月%d日' }}</time>
    </li>
    {% endfor %}
  </ul>
  {% else %}
  <p>記事は準備中です。</p>
  {% endif %}
</section>
