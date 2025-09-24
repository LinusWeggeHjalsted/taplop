using UnityEngine;

public interface Skill
{
    int GetCurrentCooldown();
    void ReduceCooldown(int number);
    void useSkill(Vector3 targetPosition);
    void prepareSkill(Vector3 fromPosition);
}
