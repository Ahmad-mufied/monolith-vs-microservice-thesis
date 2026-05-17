import { benchmarkOptions } from "./common/config.js";
import { randomUser } from "./common/data.js";
import { loginRequest, expectStatus, expectJsonValue } from "./common/requests.js";
export { handleSummary } from "./common/summary.js";

export const options = benchmarkOptions("login");

export default function () {
  const user = randomUser();

  const response = loginRequest(user.email, user.password);

  expectStatus(response, 200, "login");
  expectJsonValue(response, "data.token", "login");
}
