using UnityEngine;

public interface Skill
{
    float GetRange();
    int GetCurrentCooldown();
    void ReduceCooldown(int number);
    void useSkill(Vector3 targetPosition);
    void prepareSkill(Vector3 fromPosition);
}
