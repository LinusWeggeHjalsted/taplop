using UnityEngine;

public class NoSkillScript : MonoBehaviour, Skill
{
    public float GetRange()
    {
        return 0;
    }

    public int GetCurrentCooldown()
    {
        return 0;
    }

    public void ReduceCooldown(int number)
    {

    }

    public void useSkill(Vector3 targetPosition)
    {
        Debug.Log("no skill equipped in this slot");
    }

    public void prepareSkill(Vector3 targetPosition)
    {
        Debug.Log("no skill equipped in this slot");
    }

}
