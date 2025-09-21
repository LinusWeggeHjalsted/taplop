using UnityEngine;

public interface Skill
{
    void useSkill(Vector3 targetPosition);
    void prepareSkill(Vector3 fromPosition);
}
